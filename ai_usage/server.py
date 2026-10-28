#!/usr/bin/env python3
"""AI usage dashboard for this Mac.

Two listeners:
  * the dashboard (default 0.0.0.0:8796), read-only, answering only home-network, Tailscale and
    loopback clients that use this Mac's name, an IP address or a name listed in local.json;
  * an OTLP/HTTP JSON receiver on 127.0.0.1:4318 for Claude Code and Codex telemetry.
A worker thread rescans the tools' local logs every minute, probes Claude's plan limits, asks
Codex for ChatGPT's and reads Antigravity's from the running Antigravity app.
"""
import argparse
import gzip
import json
import logging
import os
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from ipaddress import ip_address, ip_network
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

from . import antigravity_quota, codex_limits, local, probe, report, sources, store, telemetry

STATIC = Path(__file__).resolve().parents[1] / 'static'
TAILSCALE = ip_network('100.64.0.0/10')
HOSTS = {'localhost', local.hostname(), local.hostname() + '.local',
         *(h.lower() for h in local.settings().get('allowed_hosts', []))}
TYPES = {'.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
         '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml'}
MAX_BODY = 16 * 1024 * 1024
log = logging.getLogger('ai-usage')


def client_allowed(address):
    try:
        ip = ip_address(address)
    except ValueError:
        return False
    if getattr(ip, 'ipv4_mapped', None):
        ip = ip.ipv4_mapped
    return ip.is_loopback or ip.is_private or ip in TAILSCALE


def host_allowed(header):
    """Refuse unexpected Host names so a web page elsewhere cannot read the API by DNS rebinding."""
    host = (urlsplit('http://' + (header or '')).hostname or '').lower()
    if host in HOSTS:
        return True
    try:
        return client_allowed(host)
    except ValueError:
        return False


class Handler(BaseHTTPRequestHandler):
    db_path = None

    def log_message(self, fmt, *args):
        pass

    def handle_one_request(self):
        self.db = store.connect(self.db_path, init=False)
        try:
            super().handle_one_request()
        except (BrokenPipeError, ConnectionResetError):
            self.close_connection = True  # the client left before the reply; telemetry exporters do this at exit
        finally:
            self.db.close()


class Dashboard(Handler):
    server_version = 'ai-usage'

    def send(self, status, body, content_type='application/json', cache='no-store'):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, separators=(',', ':')).encode()
        self.send_response(status)
        self.send_header('Content-Type', content_type)
        self.send_header('Content-Length', str(len(body)))
        self.send_header('Cache-Control', cache)
        self.send_header('X-Content-Type-Options', 'nosniff')
        self.send_header('Referrer-Policy', 'no-referrer')
        self.send_header('Content-Security-Policy', "default-src 'self'; style-src 'self' 'unsafe-inline'; "
                         "script-src 'self'; img-src 'self' data:; frame-ancestors 'none'")
        self.end_headers()
        if self.command != 'HEAD':
            self.wfile.write(body)

    def do_HEAD(self):
        self.do_GET()

    def do_GET(self):
        if not client_allowed(self.client_address[0]) or not host_allowed(self.headers.get('Host')):
            self.send(403, {'error': 'Open this dashboard from the home network or Tailscale.'})
            return
        url = urlsplit(self.path)
        if url.path == '/api/summary':
            query = parse_qs(url.query)
            self.send(200, report.summary(self.db, (query.get('range') or ['7d'])[0]))
        elif url.path == '/api/health':
            self.send(200, {'ok': True, 'last_scan': store.get_kv(self.db, 'last_scan')})
        else:
            name = 'index.html' if url.path in ('/', '') else url.path.lstrip('/')
            path = (STATIC / name).resolve()
            if STATIC not in path.parents or not path.is_file() or path.suffix not in TYPES:
                self.send(404, {'error': 'not found'})
                return
            self.send(200, path.read_bytes(), TYPES[path.suffix], 'no-cache')


class Collector(Handler):
    """Loopback-only OTLP/HTTP receiver. Only JSON encoding is supported (OTEL_EXPORTER_OTLP_PROTOCOL=http/json)."""
    server_version = 'ai-usage-otlp'

    def reply(self, status, body=b'{}'):
        self.send_response(status)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if not ip_address(self.client_address[0]).is_loopback:
            self.reply(403)
            return
        length = int(self.headers.get('Content-Length') or 0)
        if not 0 < length <= MAX_BODY:
            self.reply(413)
            return
        body = self.rfile.read(length)
        if self.headers.get('Content-Encoding') == 'gzip':
            body = gzip.decompress(body)
        if 'json' not in (self.headers.get('Content-Type') or ''):
            self.reply(415)
            return
        path = urlsplit(self.path).path
        if path == '/v1/logs':
            try:
                count = telemetry.ingest_logs(self.db, body)
            except (ValueError, KeyError, TypeError) as error:
                log.warning('bad OTLP logs payload: %s', error)
                self.reply(400)
                return
            if count:
                store.set_kv(self.db, 'telemetry_last', int(time.time()))
                store.set_kv(self.db, 'telemetry_count', (store.get_kv(self.db, 'telemetry_count', 0) or 0) + count)
        elif path not in ('/v1/metrics', '/v1/traces'):
            self.reply(404)
            return
        self.reply(200)


def otel_env(port, job):
    return {'CLAUDE_CODE_ENABLE_TELEMETRY': '1', 'OTEL_LOGS_EXPORTER': 'otlp', 'OTEL_METRICS_EXPORTER': 'none',
            'OTEL_EXPORTER_OTLP_PROTOCOL': 'http/json', 'OTEL_EXPORTER_OTLP_ENDPOINT': f'http://127.0.0.1:{port}',
            'OTEL_LOGS_EXPORT_INTERVAL': '2000', 'OTEL_RESOURCE_ATTRIBUTES': f'ai_usage.job={job}'}


_beat = {'scan': time.time()}


def worker(db_path, scan_interval):
    """Rescan the tools' logs every scan_interval seconds."""
    db = store.connect(db_path, init=False)
    while True:
        started = time.time()
        try:
            result = sources.scan_all(db)
            store.set_kv(db, 'last_scan', int(started))
            store.set_kv(db, 'scan_result', result)
        except Exception:
            log.exception('scan failed')
        _beat['scan'] = time.time()
        time.sleep(max(5, scan_interval - (time.time() - started)))


def pollers(db_path, probe_interval, otel_port, quota_interval, codex_interval=600):
    """Plan-limit reads run apart from the scans, so a slow probe never holds up fresh usage."""
    db = store.connect(db_path, init=False)
    while True:
        if probe_interval and probe.due(db, probe_interval):
            try:
                probe.run(db, otel_env(otel_port, 'ai-usage-probe'))
            except Exception:
                log.exception('probe failed')
        if quota_interval and antigravity_quota.due(db, quota_interval):
            try:
                antigravity_quota.poll(db)
            except Exception:
                log.exception('Antigravity quota poll failed')
        if codex_interval and codex_limits.due(db, codex_interval):
            try:
                codex_limits.poll(db)
            except Exception:
                log.exception('Codex limit read failed')
        time.sleep(30)


def watchdog(limit):
    """Exit when scans have stalled, so launchd starts a fresh process."""
    while True:
        time.sleep(60)
        stalled = time.time() - _beat['scan']
        if stalled > limit:
            log.error('no completed scan for %d s; exiting for launchd to restart', stalled)
            os._exit(1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--host', default='0.0.0.0')
    parser.add_argument('--port', type=int, default=8796)
    parser.add_argument('--otlp-port', type=int, default=4318)
    parser.add_argument('--allow-host', action='append', default=[],
                        help='another Host name to answer to, such as a Tailscale MagicDNS name; repeatable')
    parser.add_argument('--scan-interval', type=int, default=60)
    parser.add_argument('--probe-interval', type=int, default=1200, help='seconds between Claude limit probes; 0 disables')
    parser.add_argument('--quota-interval', type=int, default=300, help='seconds between Antigravity quota reads; 0 disables')
    parser.add_argument('--codex-interval', type=int, default=600, help='seconds between ChatGPT limit reads; 0 disables')
    parser.add_argument('--db', help='SQLite path (default ~/Library/Application Support/ai-usage/usage.sqlite)')
    args = parser.parse_args()
    logging.basicConfig(level=logging.INFO, format='%(asctime)s %(levelname)s %(message)s')

    HOSTS.update(h.lower() for h in args.allow_host)
    store.connect(args.db).close()
    Handler.db_path = args.db
    collector = ThreadingHTTPServer(('127.0.0.1', args.otlp_port), Collector)
    dashboard = ThreadingHTTPServer((args.host, args.port), Dashboard)
    threading.Thread(target=collector.serve_forever, daemon=True, name='otlp').start()
    threading.Thread(target=worker, args=(args.db, args.scan_interval), daemon=True, name='worker').start()
    threading.Thread(target=pollers, args=(args.db, args.probe_interval, args.otlp_port, args.quota_interval, args.codex_interval),
                     daemon=True, name='pollers').start()
    threading.Thread(target=watchdog, args=(max(900, args.scan_interval * 10),), daemon=True, name='watchdog').start()
    log.info('dashboard on %s:%s, OTLP on 127.0.0.1:%s', args.host, args.port, args.otlp_port)
    dashboard.serve_forever()


if __name__ == '__main__':
    main()
