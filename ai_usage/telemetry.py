"""OTLP/HTTP JSON log ingestion for Claude Code and Codex.

Calls made with `claude -p --no-session-persistence` or `codex exec --ephemeral` leave nothing on
disk, so jobs that make them get OpenTelemetry settings in their LaunchAgent (see install.py). Each
model request then arrives here as one log record: `claude_code.api_request` or a Codex
`codex.sse_event` of kind `response.completed`. Prompts are redacted by both tools by default and
are never stored.
"""
import json

from . import jobs, pricing
from .sources import CLAUDE_PLAN, OPENAI_PLAN, iso_ts
from .store import put_events


def _value(value):
    if not isinstance(value, dict) or not value:
        return None
    kind, inner = next(iter(value.items()))
    if kind == 'arrayValue':
        return [_value(v) for v in inner.get('values', [])]
    if kind == 'kvlistValue':
        return {item['key']: _value(item.get('value')) for item in inner.get('values', [])}
    if kind == 'intValue':
        return int(inner)
    return inner


def _attrs(items):
    return {item.get('key'): _value(item.get('value')) for item in items or [] if isinstance(item, dict)}


def _int(value):
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return 0


def records(payload):
    """Yield (resource attributes, record attributes, record body) from an OTLP logs export."""
    for resource_logs in payload.get('resourceLogs') or []:
        resource = _attrs((resource_logs.get('resource') or {}).get('attributes'))
        for scope in resource_logs.get('scopeLogs') or []:
            for record in scope.get('logRecords') or []:
                yield resource, _attrs(record.get('attributes')), _value(record.get('body'))


def claude_event(resource, attrs):
    request = attrs.get('request_id')
    model = attrs.get('model')
    if not request or not model:
        return None
    tokens = dict(input=_int(attrs.get('input_tokens')), cache_read=_int(attrs.get('cache_read_tokens')),
                  cache_write=_int(attrs.get('cache_creation_tokens')), output=_int(attrs.get('output_tokens')),
                  reasoning=0)
    reported = attrs.get('cost_usd')
    cost = float(reported) if reported not in (None, '') else pricing.cost(
        model, tokens['input'], tokens['cache_read'], tokens['cache_write'], tokens['output'],
        _int(attrs.get('cache_creation_1h_tokens')), attrs.get('speed'))
    job = jobs.from_telemetry(resource) or 'Claude Code (scripts)'
    return dict(id='anthropic:' + request, ts=iso_ts(attrs.get('event.timestamp')) or 0, source='otel_claude',
                vendor='anthropic', plan=CLAUDE_PLAN, tool='Claude Code', model=pricing.normalize_model(model),
                job=job, detail=resource.get('ai_usage.detail'), session=attrs.get('session.id'), cwd=None,
                cost_usd=cost, cost_basis='reported' if reported not in (None, '') else 'priced',
                speed=attrs.get('speed'), **tokens)


def codex_event(resource, attrs):
    if attrs.get('event.kind') != 'response.completed':
        return None
    model = attrs.get('model') or attrs.get('slug') or 'unknown'
    total_input, cached = _int(attrs.get('input_token_count')), _int(attrs.get('cached_token_count'))
    tokens = dict(input=max(total_input - cached, 0), cache_read=cached,
                  cache_write=_int(attrs.get('cache_write_token_count')),
                  output=_int(attrs.get('output_token_count')), reasoning=_int(attrs.get('reasoning_token_count')))
    if not any(tokens.values()):
        return None
    session, stamp = attrs.get('conversation.id'), attrs.get('event.timestamp')
    cost = pricing.cost(model, tokens['input'], tokens['cache_read'], tokens['cache_write'], tokens['output'])
    job = jobs.from_telemetry(resource) or 'Codex (scripts)'
    return dict(id=f'openai:otel:{session}:{stamp}:{total_input}', ts=iso_ts(stamp) or 0, source='otel_codex',
                vendor='openai', plan=OPENAI_PLAN, tool='Codex', model=pricing.normalize_model(model), job=job,
                detail=resource.get('ai_usage.detail'), session=session, cwd=None, cost_usd=cost,
                cost_basis='priced' if cost is not None else 'unpriced', speed=None, **tokens)


def ingest_logs(db, body):
    payload = json.loads(body)
    events = []
    for resource, attrs, record_body in records(payload):
        name = attrs.get('event.name') or record_body
        service = str(resource.get('service.name') or '')
        if name in ('api_request', 'claude_code.api_request') and service.startswith('claude'):
            event = claude_event(resource, attrs)
        elif name == 'codex.sse_event':
            event = codex_event(resource, attrs)
        else:
            continue
        if event:
            events.append(event)
    put_events(db, events)
    return len(events)
