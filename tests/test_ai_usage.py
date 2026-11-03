import json
import os
import sqlite3
import tempfile
import time
import unittest
from datetime import datetime, timezone
from pathlib import Path
from unittest import mock

from ai_usage import antigravity_quota, codex_limits, jobs, local, pricing, probe, protowire, report, server, sources, store, telemetry

# Job rules for the tests, independent of the example jobs.json and of any jobs.local.json.
RULES = {
    'telemetry_attribute': 'ai_usage.job',
    'telemetry_jobs': {'nightly-report-health': 'nightly-report'},
    'prompt_rules': [
        {'contains': 'TELEMETRY_JSON', 'job': 'nightly-report', 'detail': 'health monitor'},
        {'regex': "^This is an automated (?:scheduled |daily )?run of (?:the )?(?P<name>[^.]+?)(?: \\(|\\.|$)",
         'job': 'Scheduled: {name}'},
    ],
    'cwd_rules': [{'prefix': '~/Developer/nightly-report', 'job': 'nightly-report'}],
    'scheduled_names': {},
}
_rules_dir = tempfile.TemporaryDirectory()
_patches = []


def setUpModule():
    path = Path(_rules_dir.name) / 'jobs.json'
    path.write_text(json.dumps(RULES))
    _patches.extend([mock.patch.object(jobs, 'JOBS_PATH', path),
                     mock.patch.object(jobs, 'LOCAL_JOBS_PATH', Path(_rules_dir.name) / 'missing.json')])
    for patch in _patches:
        patch.start()


def tearDownModule():
    for patch in _patches:
        patch.stop()
    _rules_dir.cleanup()


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
        self.assertEqual(jobs.from_prompt('Check the service health...\nTELEMETRY_JSON: {}'),
                         ('nightly-report', 'health monitor'))
        self.assertIsNone(jobs.from_prompt('fix my widget'))

    def test_scheduled_names_and_telemetry(self):
        self.assertEqual(jobs.scheduled('weekly-inbox-digest'), 'Scheduled: Weekly Inbox Digest')
        self.assertEqual(jobs.from_telemetry({'ai_usage.job': 'nightly-report-health'}), 'nightly-report')
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
        self.make_db(base / 'conversations/abc.db', 'Check the service health.\nTELEMETRY_JSON: {}')
        sources.scan_antigravity(self.db, {'antigravity_cli': (base, 'Antigravity CLI')})
        rows = self.events()
        self.assertEqual(len(rows), 1)
        row = rows[0]
        self.assertEqual((row['model'], row['input'], row['output'], row['reasoning'], row['ts']),
                         ('gemini-3.8-flash', 16947, 931, 840, 1793072728))
        self.assertEqual((row['job'], row['detail'], row['plan']), ('nightly-report', 'health monitor', 'Google (Antigravity)'))
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
        claude = self.otlp({'service.name': 'claude-code', 'ai_usage.job': 'price-checker'},
                           {'event.name': 'api_request', 'event.timestamp': '2026-10-27T04:10:47.863Z',
                            'request_id': 'req_9', 'model': 'claude-opus-5-5', 'input_tokens': 2, 'output_tokens': 4,
                            'cache_read_tokens': 10, 'cache_creation_tokens': 0, 'cost_usd': 0.5, 'session.id': 'x', 'effort': 'max'})
        codex = self.otlp({'service.name': 'codex_exec', 'ai_usage.job': 'nightly-report'},
                          {'event.name': 'codex.sse_event', 'event.kind': 'response.completed', 'model': 'gpt-6-astra',
                           'input_token_count': '21146', 'cached_token_count': '10112', 'output_token_count': '5',
                           'reasoning_token_count': '0', 'conversation.id': 'conv', 'event.timestamp': '2026-10-27T04:11:22Z',
                           'model_reasoning_effort': 'xhigh'})
        self.assertEqual(telemetry.ingest_logs(self.db, claude), 1)
        self.assertEqual(telemetry.ingest_logs(self.db, codex), 1)
        rows = {r['source']: r for r in self.events()}
        self.assertEqual((rows['otel_claude']['job'], rows['otel_claude']['cost_usd'], rows['otel_claude']['cost_basis']),
                         ('price-checker', 0.5, 'reported'))
        self.assertEqual((rows['otel_codex']['job'], rows['otel_codex']['input'], rows['otel_codex']['cache_read']),
                         ('nightly-report', 11034, 10112))
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

    def test_drops_a_window_claude_stopped_reporting_once_it_has_reset(self):
        start = 1793000000
        weekly = lambda used: {'status': 'allowed', 'overageStatus': 'allowed', 'unifiedWindows': {
            'seven_day': {'utilization': used, 'resetsAt': start + 4 * 86400}}}
        windows = lambda: {(r['vendor'], r['window']): r['used_pct'] for r in self.db.execute('SELECT * FROM limits')}
        probe.record(self.db, {'status': 'allowed', 'unifiedWindows': {
            'five_hour': {'utilization': 0.02, 'resetsAt': start + 3600},
            'seven_day': {'utilization': 0.10, 'resetsAt': start + 4 * 86400}}}, observed_at=start)
        store.put_limit(self.db, 'openai', 'codex_primary', 40.0, start + 60, 'pro', {}, start)
        # Until its reset the 5-hour reading still stands, though the reply left it out.
        probe.record(self.db, weekly(0.11), observed_at=start + 1800)
        self.assertEqual(windows(), {('anthropic', 'five_hour'): 2.0, ('anthropic', 'seven_day'): 11.0,
                                     ('openai', 'codex_primary'): 40.0})
        # After it, the reading describes a window that is over. Its history and other vendors stay.
        probe.record(self.db, weekly(0.12), observed_at=start + 7200)
        self.assertEqual(windows(), {('anthropic', 'seven_day'): 12.0, ('openai', 'codex_primary'): 40.0})
        self.assertEqual({r['window'] for r in self.db.execute("SELECT window FROM limit_history WHERE vendor='anthropic'")},
                         {'five_hour', 'seven_day'})
        # A reply without windows changes nothing.
        store.put_limit(self.db, 'anthropic', 'five_hour', 5.0, start + 3 * 3600, 'Claude Max 20x', {}, start + 2 * 3600)
        probe.record(self.db, {'status': 'allowed'}, observed_at=start + 4 * 3600)
        self.assertEqual(windows()[('anthropic', 'five_hour')], 5.0)

    def test_finds_the_desktop_apps_cli_when_the_link_is_stale(self):
        home = self.dir / 'home'
        (home / '.local/bin').mkdir(parents=True)
        (home / '.local/bin/claude').symlink_to(home / probe.DESKTOP_CLI / '2.1.9/old/claude.app/Contents/MacOS/claude')
        for version in ('2.1.10', '2.1.9b', '2.1.11'):
            binary = home / probe.DESKTOP_CLI / version / 'abc123/claude.app/Contents/MacOS/claude'
            binary.parent.mkdir(parents=True)
            binary.write_text('#!/bin/sh\n')
            binary.chmod(0o755 if version != '2.1.11' else 0o644)
        with mock.patch.object(probe.shutil, 'which', return_value=None), mock.patch.object(Path, 'home', return_value=home):
            self.assertEqual(probe.claude_binary(), str(home / probe.DESKTOP_CLI / '2.1.10/abc123/claude.app/Contents/MacOS/claude'))
            for binary in (home / probe.DESKTOP_CLI).glob('*/*/claude.app/Contents/MacOS/claude'):
                binary.unlink()
            self.assertIsNone(probe.claude_binary())


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

    def test_infers_monthly_price_from_user_tier(self):
        self.assertEqual(antigravity_quota.tier_monthly_usd({
            'id': 'g1-ultra-tier', 'description': 'Google AI Ultra',
            'upgradeSubscriptionText': 'You are subscribed to the best Google AI plan.'}), 199.99)
        self.assertEqual(antigravity_quota.tier_monthly_usd({
            'id': 'g1-ultra-tier', 'description': 'Google AI Ultra',
            'upgradeSubscriptionUri': 'https://one.google.com/upgrade'}), 99.99)
        self.assertEqual(antigravity_quota.tier_monthly_usd({
            'id': 'g1-pro-tier', 'description': 'Google AI Pro'}), 19.99)
        store.set_kv(self.db, 'antigravity_monthly_usd', 199.99)
        google_plan = next(p for p in report.summary(self.db, '7d')['plans'] if p['vendor'] == 'google')
        self.assertEqual(google_plan['monthly_usd'], 199.99)


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
        store.put_events(self.db, [dict(base, job='Camera check', input=10, output=20, cost_usd=0.5)])
        row = self.events()[0]
        self.assertEqual((row['job'], row['output'], row['cost_usd']), ('Camera check', 50, 1.0))


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
        prices = {r['model']: r for r in data['price_table']}
        self.assertEqual(list(prices), ['gpt-6.1-sol', 'gemini-3.8-flash', 'gemini-4-argon', 'claude-opus-5-5', 'gpt-6-astra'])
        self.assertEqual(prices['claude-opus-5-5']['efforts'], {'high': {'requests': 1, 'per_request': 1.0}})
        self.assertEqual((prices['gpt-6.1-sol']['price']['cache_read'], prices['gemini-4-argon']['vendor']), (0.1, 'google'))

    def test_widget_payload(self):
        now = time.time()
        store.put_events(self.db, [
            dict(id='a', ts=int(now) - 60, source='claude_transcript', vendor='anthropic', plan='Claude Max 20x',
                 tool='Claude Code', model='claude-opus-5-5', job='Scheduled: Morning Brief', input=10, cache_read=30,
                 output=5, cost_usd=1.5),
            dict(id='b', ts=int(now) - 120, source='codex_rollout', vendor='openai', plan='ChatGPT Pro', tool='Codex',
                 model='gpt-6-astra', job='Codex (interactive)', input=10, output=5, cost_usd=2.0),
        ])
        store.put_limit(self.db, 'anthropic', 'five_hour', 2.0, int(now) + 600, 'Claude Max 20x',
                        {'status': 'allowed', 'overageStatus': 'rejected'}, int(now))
        store.put_limit(self.db, 'anthropic', 'seven_day', 75.5, int(now) + 86400, 'Claude Max 20x', {}, int(now))
        store.put_limit(self.db, 'openai', 'codex_secondary', 95.0, int(now) + 3600, 'pro', {'window_minutes': 10080}, int(now))
        for order, group in enumerate(('Gemini Models', 'Claude and GPT models')):
            store.put_limit(self.db, 'google', f'{order}-5h', 120.0 if order else 10.0, int(now) + 60, 'Google AI Ultra',
                            {'group': group, 'window': '5h', 'order': order}, int(now))
        store.set_kv(self.db, 'antigravity_tier', 'Google AI Ultra')
        store.set_kv(self.db, 'probe_error', 'Claude CLI not found')
        data = report.widget(self.db, '7d', now)
        self.assertEqual(data['range_label'], 'Last 7 days')
        plans = {p['vendor']: p for p in data['plans']}
        self.assertEqual(list(plans), ['anthropic', 'openai', 'google'])
        claude = plans['anthropic']
        self.assertEqual([(w['label'], w['left_pct'], w['level']) for w in claude['windows']],
                         [('5-hour', 98.0, 'good'), ('Weekly', 24.5, 'warning')])
        self.assertEqual((claude['notes'], claude['warning'], claude['warning_short'], claude['short']),
                         (['Extra usage: off'], 'Probe: Claude CLI not found', 'CLI not found', 'Claude'))
        self.assertEqual((claude['requests'], claude['cost']), (1, 1.5))
        self.assertEqual([(w['label'], w['left_pct'], w['level']) for w in plans['openai']['windows']],
                         [('Weekly', 5.0, 'critical')])
        self.assertEqual((plans['openai']['warning'], plans['openai']['warning_short']), (None, None))
        google = plans['google']
        self.assertEqual(google['title'], 'Google AI Ultra (Antigravity)')
        self.assertEqual([(w['group_short'], w['left_pct']) for w in google['windows']],
                         [('Gemini', 90.0), ('Claude and GPT', 0.0)])
        totals = data['totals']
        self.assertEqual((totals['requests'], totals['cost'], totals['background_cost']), (2, 3.5, 1.5))
        self.assertEqual(totals['top_background_job'], {'job': 'Scheduled: Morning Brief', 'cost': 1.5})
        self.assertEqual(totals['cache_share'], round(30 / 60 * 100))
        self.assertEqual(report.short_group(None), None)
        self.assertEqual([report.short_warning(e) for e in (
            'The Antigravity app is not running on this Mac, so limits are not refreshing.',
            'Antigravity is running but did not return quota: timed out', 'Codex returned no rate limits',
            'Probe: no rate_limit_event (exit 1): error', 'process list failed: denied')],
            ['app not running', 'no limits returned', 'no limits returned', 'limit check failed', 'limit check failed'])
        self.assertEqual(report.short_group('Models'), 'Models')

    def test_widget_takes_extra_usage_from_the_newest_claude_reading(self):
        now = time.time()
        store.put_limit(self.db, 'anthropic', 'five_hour', 2.0, int(now) + 600, 'Claude Max 20x',
                        {'status': 'allowed', 'overageStatus': 'rejected'}, int(now) - 3 * 86400)
        store.put_limit(self.db, 'anthropic', 'seven_day', 21.0, int(now) + 86400, 'Claude Max 20x',
                        {'status': 'allowed', 'overageStatus': 'allowed', 'isUsingOverage': True}, int(now) - 60)
        claude = {p['vendor']: p for p in report.widget(self.db, '7d', now)['plans']}['anthropic']
        self.assertEqual(claude['notes'], ['Extra usage: allowed (in use)'])

    def test_dashboard_serves_widget_api_and_relative_page(self):
        import http.client
        import threading
        self.db.close()
        self.db = store.connect(self.dir / 'usage.sqlite')
        with mock.patch.object(server.Handler, 'db_path', self.dir / 'usage.sqlite'):
            httpd = server.ThreadingHTTPServer(('127.0.0.1', 0), server.Dashboard)
            thread = threading.Thread(target=httpd.serve_forever, daemon=True)
            thread.start()
            try:
                def get(path):
                    conn = http.client.HTTPConnection('127.0.0.1', httpd.server_port, timeout=10)
                    conn.request('GET', path, headers={'Host': f'127.0.0.1:{httpd.server_port}'})
                    response = conn.getresponse()
                    result = response.status, response.read()
                    conn.close()
                    return result
                status, body = get('/api/widget?range=today')
                self.assertEqual(status, 200)
                self.assertEqual(json.loads(body)['range'], 'today')
                status, body = get('/app.js')
                self.assertEqual(status, 200)
                # Relative URLs, so the page also works behind a proxy that serves it under a path.
                self.assertNotIn(b"fetch('/", body)
                status, body = get('/')
                self.assertNotIn(b'href="/', body)
                self.assertNotIn(b'src="/', body)
            finally:
                httpd.shutdown()
                httpd.server_close()
                thread.join()

    def test_access_checks(self):
        self.assertTrue(server.client_allowed('192.168.1.20'))
        self.assertTrue(server.client_allowed('100.101.102.103'))
        self.assertTrue(server.client_allowed('::ffff:127.0.0.1'))
        self.assertFalse(server.client_allowed('8.8.8.8'))
        with mock.patch.object(server, 'HOSTS', {'localhost', 'my-mac', 'my-mac.local', 'my-mac.example.ts.net'}):
            self.assertTrue(server.host_allowed('my-mac.local:8796'))
            self.assertTrue(server.host_allowed('My-Mac.Example.ts.net:8796'))
            self.assertTrue(server.host_allowed('192.168.1.33:8796'))
            self.assertFalse(server.host_allowed('evil.example:8796'))
            self.assertFalse(server.host_allowed('other-mac.local:8796'))

    def test_hostname_and_local_settings(self):
        with mock.patch('socket.gethostname', return_value='My-Mac.local'):
            self.assertEqual(local.hostname(), 'my-mac')
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / 'local.json'
            with mock.patch.object(local, 'PATH', path):
                self.assertEqual(local.settings(), {})
                path.write_text(json.dumps({'allowed_hosts': ['my-mac.example.ts.net']}))
                self.assertEqual(local.settings()['allowed_hosts'], ['my-mac.example.ts.net'])

    def test_local_job_rules_take_precedence(self):
        with tempfile.TemporaryDirectory() as tmp:
            override = Path(tmp) / 'jobs.local.json'
            override.write_text(json.dumps({'prompt_rules': [{'startswith': 'Tidy', 'job': 'Cleanup'}]}))
            with mock.patch.object(jobs, 'LOCAL_JOBS_PATH', override):
                self.assertEqual(jobs.jobs_path(), override)
                self.assertEqual(jobs.from_prompt('Tidy the downloads folder'), ('Cleanup', None))
        self.assertIsNone(jobs.from_prompt('Tidy the downloads folder'))


if __name__ == '__main__':
    unittest.main()
