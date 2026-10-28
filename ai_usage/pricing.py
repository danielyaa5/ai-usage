"""API-equivalent cost from token counts, using pricing.json."""
import json
import os
import re
from pathlib import Path

PRICING_PATH = Path(__file__).with_name('pricing.json')
_cache = {'mtime': None, 'data': None}


def table():
    mtime = os.path.getmtime(PRICING_PATH)
    if _cache['mtime'] != mtime:
        _cache['data'] = json.loads(PRICING_PATH.read_text())
        _cache['mtime'] = mtime
    return _cache['data']


def normalize_model(model):
    """'claude-opus-5-5[1m]' -> 'claude-opus-5-5'; aliases such as 'sonnet' resolve to full ids."""
    model = re.sub(r'\[.*?\]$', '', str(model or '').strip().lower())
    return table().get('aliases', {}).get(model, model) or 'unknown'


EFFORTS = ('low', 'medium', 'high', 'xhigh', 'max', 'auto')
_EFFORT_SUFFIX = re.compile(r'-(low|medium|high|xhigh|max|tiered)$')


def effort_name(value):
    """'High' / 'xhigh' / 'tiered' -> 'high' / 'xhigh' / 'auto'; anything else -> None."""
    value = str(value or '').strip().lower()
    value = {'tiered': 'auto', 'extra high': 'xhigh', 'extra-high': 'xhigh'}.get(value, value)
    return value if value in EFFORTS else None


def split_effort(model):
    """Antigravity names some models with their effort: 'gemini-4-argon-high' -> ('gemini-4-argon', 'high')."""
    model = str(model or '')
    match = _EFFORT_SUFFIX.search(model)
    if not match:
        return model, None
    return model[:match.start()], effort_name(match.group(1))


def price_for(model):
    models = table()['models']
    model = normalize_model(model)
    best = max((key for key in models if model.startswith(key)), key=len, default=None)
    return models.get(best) if best else None


def cost(model, input_tokens=0, cache_read=0, cache_write=0, output=0, cache_write_1h=0, speed=None):
    """Return dollars, or None when the model has no price. cache_write counts 5-minute writes;
    cache_write_1h is the part of cache writes held for an hour (priced at 2x input)."""
    price = price_for(model)
    if not price:
        return None
    per = 1e-6
    total = (input_tokens * price['input'] + output * price['output']
             + cache_read * price.get('cache_read', price['input'] * 0.1)
             + max(cache_write - cache_write_1h, 0) * price.get('cache_write', price['input'] * 1.25)
             + cache_write_1h * price.get('cache_write_1h', price['input'] * 2)) * per
    if speed == 'fast':
        total *= price.get('fast_multiplier', 1.0)
    return round(total, 8)
