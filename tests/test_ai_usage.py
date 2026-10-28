import json
import os
import sqlite3
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from ai_usage import antigravity_quota, codex_limits, jobs, pricing, probe, protowire, report, server, sources, store, telemetry


def varint(n):
    out = bytearray()
    while True:
        byte = n & 0x7F
        n >>= 7
        out.append(byte | (0x80 if n else 0))
        if not n:
            return bytes(out)


def field(number, value):
    if isinstance(value, int):
        return varint(number << 3) + varint(value)
    data = value.encode() if isinstance(value, str) else value
    return varint(number << 3 | 2) + varint(len(data)) + data


def usage_msg(enum, inp, out, thinking=0, cache_read=0, response='r1'):
    return (field(1, enum) + field(2, inp) + field(3, out) + (field(5, cache_read) if cache_read else b'')
            + field(9, thinking) + field(10, out - thinking) + field(11, response))


class Base(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.db = store.connect(self.dir / 'usage.sqlite')

    def tearDown(self):
        self.db.close()
        self.tmp.cleanup()

    def events(self):
        return [dict(r) for r in self.db.execute('SELECT * FROM events ORDER BY ts')]


class PricingTest(unittest.TestCase):
    def test_matches_claude_code_reported_cost(self):
        # Probe result from Claude Code 2.1.304: costUSD 0.00051629 for this usage.
        self.assertAlmostEqual(pricing.cost('claude-haiku-5-5', 2, 649, 2538, 4, cache_write_1h=2538), 0.00051629, 8)

    def test_prefix_and_aliases(self):
        self.assertEqual(pricing.normalize_model('claude-opus-5-5[1m]'), 'claude-opus-5-5')
        self.assertEqual(pricing.price_for('claude-opus-5-5-high')['input'], 4.0)
        self.assertEqual(pricing.price_for('claude-opus-5')['input'], 5.0)
        self.assertEqual(pricing.price_for('gemini-3.8-flash-tiered')['output'], 3.75)
        self.assertEqual(pricing.normalize_model('sonnet'), 'claude-sonnet-5-5')
        self.assertIsNone(pricing.cost('mystery-model', 10, 0, 0, 10))


class JobsTest(unittest.TestCase):
    def test_prompt_rules(self):
        self.assertEqual(jobs.from_prompt("This is an automated scheduled run of the Evening Brief. Run at 6 PM")[0],
                         'Scheduled: Evening Brief')
        self.assertEqual(jobs.from_prompt("This is an automated daily run of the Daily Portfolio Digest."),
                         ('Scheduled: Daily Portfolio Digest', None))
        self.assertEqual(jobs.from_prompt('CRITICAL INSTRUCTION: Do NOT call any tools...\nTELEMETRY_JSON: {}'),
                         ('ai-trader', 'health monitor'))
        self.assertIsNone(jobs.from_prompt('fix my widget'))

    def test_scheduled_names_and_telemetry(self):
        self.assertEqual(jobs.scheduled('weekly-inbox-digest'), 'Scheduled: Weekly Inbox Digest')
        self.assertEqual(jobs.from_telemetry({'ai_usage.job': 'ai-trader-health'}), 'ai-trader')
        self.assertIsNone(jobs.from_telemetry({}))


class ClaudeTranscriptTest(Base):
    def test_dedupes_streamed_blocks_and_uses_desktop_task(self):
        projects = self.dir / 'projects/-x'
        projects.mkdir(parents=True)
        desktop = self.dir / 'desktop/acct/org'
        desktop.mkdir(parents=True)
        (desktop / 'local_1.json').write_text(json.dumps(
            {'cliSessionId': 's1', 'title': 'Morning brief (8 AM daily)', 'scheduledTaskId': 'morning-brief'}))
        usage = {'input_tokens': 2, 'cache_read_input_tokens': 1000, 'cache_creation_input_tokens': 500,
                 'cache_creation': {'ephemeral_1h_input_tokens': 500}, 'output_tokens': 10}
        line = {'type': 'assistant', 'sessionId': 's1', 'requestId': 'req_1', 'timestamp': '2026-10-26T15:00:00Z',
                'cwd': '/Users/x', 'entrypoint': 'claude-desktop', 'effort': 'xhigh',
                'message': {'id': 'msg_1', 'model': 'claude-opus-5-5', 'usage': usage}}
        final = json.loads(json.dumps(line))
        final['message']['usage']['output_tokens'] = 250
        (projects / 's1.jsonl').write_text(json.dumps(line) + '\n' + json.dumps(final) + '\n')
        with mock.patch.object(sources, 'CLAUDE_DESKTOP_SESSIONS', self.dir / 'desktop'):
            sources.scan_claude(self.db, self.dir / 'projects')
            sources.scan_claude(self.db, self.dir / 'projects')  # unchanged file: nothing new
        rows = self.events()
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]['output'], 250)
        self.assertEqual(rows[0]['job'], 'Scheduled: Morning Brief')
        self.assertEqual(rows[0]['id'], 'anthropic:req_1')
        self.assertEqual(rows[0]['effort'], 'xhigh')
        self.assertAlmostEqual(rows[0]['cost_usd'], pricing.cost('claude-opus-5-5', 2, 1000, 500, 250, 500))

    def test_incremental_append_and_partial_line(self):
        projects = self.dir / 'projects'
        projects.mkdir()
        path = projects / 's.jsonl'
        def entry(i):
            return json.dumps({'type': 'assistant', 'sessionId': 's', 'requestId': f'req_{i}',
                               'timestamp': '2026-10-26T15:00:00Z', 'message': {'id': f'm{i}', 'model': 'claude-haiku-5-5',
                               'usage': {'input_tokens': 5, 'output_tokens': 5}}})
        path.write_text(entry(1) + '\n' + entry(2)[:20])
        with mock.patch.object(sources, 'CLAUDE_DESKTOP_SESSIONS', self.dir / 'none'):
            sources.scan_claude(self.db, projects)
            self.assertEqual(len(self.events()), 1)
            path.write_text(entry(1) + '\n' + entry(2) + '\n')
            sources.scan_claude(self.db, projects)
        self.assertEqual(len(self.events()), 2)


class CodexRolloutTest(Base):
    def test_records_usage_model_and_limits(self):
        home = self.dir / 'codex'
        folder = home / 'sessions/2026/10/26'
        folder.mkdir(parents=True)
        lines = [
            {'type': 'session_meta', 'timestamp': '2026-10-26T10:00:00Z',
             'payload': {'id': 'c1', 'cwd': '/tmp/x', 'originator': 'Codex Desktop', 'source': 'vscode'}},
            {'type': 'turn_context', 'payload': {'turn_id': 't1', 'model': 'gpt-6-astra', 'effort': 'high'}},
            {'type': 'event_msg', 'payload': {'type': 'user_message', 'message': 'hello'}},
            {'type': 'token_usage_record', 'timestamp': '2026-10-26T10:00:05Z',
             'payload': {'turn_id': 't1', 'response_id': 'resp_1', 'usage': {
                 'input_tokens': 1000, 'cached_input_tokens': 800, 'output_tokens': 50, 'reasoning_output_tokens': 20}}},
            {'type': 'event_msg', 'timestamp': '2026-10-26T10:00:06Z', 'payload': {
                'type': 'token_count', 'info': {'last_token_usage': {'input_tokens': 1000, 'output_tokens': 50}},
                'rate_limits': {'plan_type': 'pro', 'primary': {'used_percent': 64.0, 'window_minutes': 10080,
                                                               'resets_at': 1793386159}}}},
        ]
        (folder / 'rollout-2026-10-26T10-00-00-c1.jsonl').write_text('\n'.join(json.dumps(l) for l in lines) + '\n')
        with mock.patch.object(sources, 'CODEX_HOME', home):
            sources.scan_codex(self.db, home)
        rows = self.events()
        self.assertEqual(len(rows), 1)  # token_count is skipped once records exist
        row = rows[0]
        self.assertEqual((row['model'], row['input'], row['cache_read'], row['output']), ('gpt-6-astra', 200, 800, 50))
        self.assertEqual(row['job'], 'Codex (interactive)')
        self.assertEqual(row['effort'], 'high')
        limit = self.db.execute('SELECT * FROM limits').fetchone()
        self.assertEqual((limit['window'], limit['used_pct'], limit['plan']), ('codex_primary', 64.0, 'pro'))


class AntigravityTest(Base):
    def make_db(self, path, prompt):
        con = sqlite3.connect(path)
        con.executescript('CREATE TABLE steps (idx integer, step_type integer, status integer, metadata blob, step_payload blob);'
                          'CREATE TABLE gen_metadata (idx integer, data blob, size integer);')
        gen = field(1, field(4, usage_msg(1318, 16947, 931, 840)) + field(19, 'gemini-3.8-flash') + field(21, 'Gemini 3.8 Flash (High)'))
        con.execute('INSERT INTO gen_metadata VALUES (0, ?, 0)', (gen,))
        con.execute('INSERT INTO steps VALUES (0, 14, 3, ?, ?)', (field(1, field(1, 1793072723)), field(19, field(2, prompt))))
        meta = field(1, field(1, 1793072723)) + field(8, field(1, 1793072728)) + field(9, usage_msg(1318, 16947, 931, 840)) + field(11, 1318)
        con.execute('INSERT INTO steps VALUES (1, 15, 3, ?, ?)', (meta, b''))
        con.commit()
        con.close()

    def test_usage_decoding_and_attribution(self):
        self.assertEqual(protowire.usage(usage_msg(5, 10, 3, 2))['reasoning'], 2)
        base = self.dir / 'agy'
        (base / 'conversations').mkdir(parents=True)
        self.make_db(base / 'conversations/abc.db', 'CRITICAL INSTRUCTION: Do NOT call any tools.\nTELEMETRY_JSON: {}')
        sources.scan_antigravity(self.db, {'antigravity_cli': (base, 'Antigravity CLI')})
        rows = self.events()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual((row['model'], row['input'], row['output'], row['reasoning'], row['ts']),
                         ('gemini-3.8-flash', 16947, 931, 840, 1793072728))
        self.assertEqual((row['job'], row['detail'], row['plan']), ('ai-trader', 'health monitor', 'Google (Antigravity)'))
        self.assertEqual(row['effort'], 'high')

    def test_effort_from_model_suffix_and_app_labels(self):
        self.assertEqual(pricing.split_effort('gemini-3.8-flash-tiered'), ('gemini-3.8-flash', 'auto'))
        self.assertEqual(pricing.split_effort('claude-opus-5-5-high'), ('claude-opus-5-5', 'high'))
        self.assertEqual(pricing.split_effort('gpt-6-astra'), ('gpt-6-astra', None))
        self.assertEqual(sources.antigravity_effort(1419, {}, {'MODEL_PLACEHOLDER_M419': 'Gemini 4 Argon (Low)'}), 'low')
        self.assertIsNone(sources.antigravity_effort(1999, {}, {}))


class TelemetryTest(Base):
    def otlp(self, resource, attrs):
        kv = lambda d: [{'key': k, 'value': {'intValue' if isinstance(v, int) else 'stringValue': v}} for k, v in d.items()]
        return json.dumps({'resourceLogs': [{'resource': {'attributes': kv(resource)},
                                             'scopeLogs': [{'logRecords': [{'attributes': kv(attrs)}]}]}]})

    def test_claude_and_codex_records(self):
        claude = self.otlp({'service.name': 'claude-code', 'ai_usage.job': 'price-watch'},
                           {'event.name': 'api_request', 'event.timestamp': '2026-10-27T04:10:47.863Z',
                            'request_id': 'req_9', 'model': 'claude-opus-5-5', 'input_tokens': 2, 'output_tokens': 4,
                            'cache_read_tokens': 10, 'cache_creation_tokens': 0, 'cost_usd': 0.5, 'session.id': 'x', 'effort': 'max'})
        codex = self.otlp({'service.name': 'codex_exec', 'ai_usage.job': 'ai-trader'},
                          {'event.name': 'codex.sse_event', 'event.kind': 'response.completed', 'model': 'gpt-6-astra',
                           'input_token_count': '21146', 'cached_token_count': '10112', 'output_token_count': '5',
                           'reasoning_token_count': '0', 'conversation.id': 'conv', 'event.timestamp': '2026-10-27T04:11:22Z',
                           'model_reasoning_effort': 'xhigh'})
        self.assertEqual(telemetry.ingest_logs(self.db, claude), 1)
        self.assertEqual(telemetry.ingest_logs(self.db, codex), 1)
        rows = {r['source']: r for r in self.events()}
        self.assertEqual((rows['otel_claude']['job'], rows['otel_claude']['cost_usd'], rows['otel_claude']['cost_basis']),
                         ('price-watch', 0.5, 'reported'))
        self.assertEqual((rows['otel_codex']['job'], rows['otel_codex']['input'], rows['otel_codex']['cache_read']),
                         ('ai-trader', 11034, 10112))
        self.assertEqual((rows['otel_claude']['effort'], rows['otel_codex']['effort']), ('max', 'xhigh'))

    def test_codex_telemetry_yields_to_session_log(self):
        store.put_events(self.db, [dict(id='openai:resp', ts=1, source='codex_rollout', vendor='openai', plan='p', tool='Codex',
                                        model='m', job='j', session='conv', input=1, output=1)])
        store.put_events(self.db, [dict(id='openai:otel:conv:1', ts=1, source='otel_codex', vendor='openai', plan='p',
                                        tool='Codex', model='m', job='j', session='conv', input=1, output=1)])
        sources.dedupe(self.db)
        self.assertEqual([r['source'] for r in self.events()], ['codex_rollout'])


class ProbeTest(Base):
    def test_parse_rate_limit_event(self):
        out = '\n'.join([json.dumps({'type': 'system'}), json.dumps({'type': 'rate_limit_event', 'rate_limit_info': {
            'status': 'allowed', 'overageStatus': 'rejected', 'unifiedWindows': {
                'five_hour': {'utilization': 0.04, 'resetsAt': 1793076600},
                'seven_day': {'utilization': 0.31, 'resetsAt': 1793293200}}}})])
        info = probe.parse(out)
        self.assertEqual(probe.record(self.db, info), 2)
        limits = {r['window']: r['used_pct'] for r in self.db.execute('SELECT * FROM limits')}
        self.assertEqual(limits, {'five_hour': 4.0, 'seven_day': 31.0})


class AntigravityQuotaTest(Base):
    SUMMARY = {'response': {'groups': [
        {'displayName': 'Gemini Models', 'description': 'Models within this group: Gemini Flash, Gemini Pro', 'buckets': [
            {'bucketId': 'gemini-weekly', 'window': 'weekly', 'remainingFraction': 0.6429652, 'resetTime': '2026-11-02T00:45:19Z'},
            {'bucketId': 'gemini-5h', 'window': '5h', 'remainingFraction': 0.91326165, 'resetTime': '2026-10-27T15:33:31Z'}]},
        {'displayName': 'Claude and GPT models', 'buckets': [
            {'bucketId': '3p-5h', 'window': '5h', 'remainingFraction': 1, 'resetTime': '2026-10-27T16:27:41Z'}]}]}}

    def test_finds_app_server_token_first(self):
        ps = ('  9411 /Applications/Antigravity.app/Contents/Resources/bin/language_server --standalone --csrf_token abc-123 --app_data_dir antigravity\n'
              '  9442 /Applications/Antigravity.app/Contents/Resources/bin/language_server\n'
              '  7000 /Users/x/.gemini/antigravity-cli/bin/language_server --csrf_token=cli-9\n'
              '  8000 /usr/bin/other_language_server --csrf_token nope\n')
        self.assertEqual(antigravity_quota.servers(ps), [(9411, 'abc-123'), (7000, 'cli-9')])

    def test_records_buckets_as_limits(self):
        self.assertEqual(antigravity_quota.record(self.db, self.SUMMARY, 'Google AI Ultra'), 3)
        limits = [l for l in report.limits(self.db) if l['vendor'] == 'google']
        self.assertEqual([(l['group'], l['label'], l['used_pct']) for l in limits],
                         [('Gemini Models', '5-hour', 8.7), ('Gemini Models', 'Weekly', 35.7),
                          ('Claude and GPT models', '5-hour', 0.0)])
        self.assertEqual(limits[0]['plan'], 'Google AI Ultra')
        self.assertEqual(limits[0]['resets_at'], int(datetime(2026, 10, 27, 15, 33, 31, tzinfo=timezone.utc).timestamp()))


class CodexLimitsTest(Base):
    def test_newer_reading_replaces_session_log_value(self):
        store.put_limit(self.db, 'openai', 'codex_primary', 16.0, 1793600101, 'pro', {'window_minutes': 10080}, observed_at=100)
        result = {'rateLimitsByLimitId': {'codex': {'limitId': 'codex', 'planType': 'pro', 'secondary': None,
                                                    'primary': {'usedPercent': 25, 'windowDurationMins': 10080, 'resetsAt': 1793600101}}}}
        self.assertEqual(codex_limits.record(self.db, result, observed_at=200), 1)
        limit = [l for l in report.limits(self.db) if l['vendor'] == 'openai'][0]
        self.assertEqual((limit['label'], limit['used_pct'], limit['observed_at']), ('Weekly', 25.0, 200))


class StoreTest(Base):
    def test_repeat_refreshes_job_and_keeps_larger_counts(self):
        base = dict(id='x', ts=1, source='antigravity_cli', vendor='google', plan='p', tool='t', model='m')
        store.put_events(self.db, [dict(base, job='Antigravity CLI (other)', input=10, output=50, cost_usd=1.0)])
        store.put_events(self.db, [dict(base, job='Gate camera (shadow AI)', input=10, output=20, cost_usd=0.5)])
        row = self.events()[0]
        self.assertEqual((row['job'], row['output'], row['cost_usd']), ('Gate camera (shadow AI)', 50, 1.0))


class MigrationTest(Base):
    def test_effort_suffix_moves_out_of_stored_model_names(self):
        store.put_events(self.db, [dict(id='g', ts=1, source='antigravity_cli', vendor='anthropic', plan='p', tool='t',
                                        model='claude-opus-5-5-high', job='j', output=1)])
        sources.split_stored_models(self.db)
        row = self.events()[0]
        self.assertEqual((row['model'], row['effort']), ('claude-opus-5-5', 'high'))


class ReportAndServerTest(Base):
    def test_summary_buckets_and_jobs(self):
        now = time.time()
        store.put_events(self.db, [
            dict(id='a', ts=int(now) - 60, source='claude_transcript', vendor='anthropic', plan='Claude Max 20x',
                 tool='Claude Code', model='claude-opus-5-5', job='Scheduled: Morning Brief', input=10, output=5, cost_usd=1.0,
                 effort='high'),
            dict(id='b', ts=int(now) - 120, source='codex_rollout', vendor='openai', plan='ChatGPT Pro', tool='Codex',
                 model='gpt-6-astra', job='Codex (interactive)', input=10, output=5, cost_usd=2.0),
        ])
        data = report.summary(self.db, '7d', now)
        self.assertEqual(len(data['buckets']), 7)
        self.assertEqual(data['totals']['requests'], 2)
        self.assertEqual(data['jobs'][0]['job'], 'Codex (interactive)')
        self.assertFalse(data['jobs'][0]['automated'])
        self.assertTrue(data['jobs'][1]['automated'])
        self.assertEqual([(e['effort'], e['requests']) for e in data['efforts']], [('high', 1), ('unknown', 1)])
        opus = next(m for m in data['models'] if m['model'] == 'claude-opus-5-5')
        self.assertEqual([e['effort'] for e in opus['efforts']], ['high'])
        self.assertEqual((opus['price']['input'], opus['price']['output']), (4.0, 20.0))
        self.assertEqual(set(data['series']), {'plan', 'model', 'effort'})
        self.assertEqual(data['series_order']['model'], ['gpt-6-astra', 'claude-opus-5-5'])
        self.assertEqual(sorted(data['series']['effort']), ['high', 'unknown'])

    def test_access_checks(self):
        self.assertTrue(server.client_allowed('192.168.1.20'))
        self.assertTrue(server.client_allowed('100.101.102.103'))
        self.assertTrue(server.client_allowed('::ffff:127.0.0.1'))
        self.assertFalse(server.client_allowed('8.8.8.8'))
        self.assertTrue(server.host_allowed('my-mac.local:8796'))
        self.assertTrue(server.host_allowed('192.168.1.33:8796'))
        self.assertFalse(server.host_allowed('evil.example:8796'))


if __name__ == '__main__':
    unittest.main()
