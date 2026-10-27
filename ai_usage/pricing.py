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
