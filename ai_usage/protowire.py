"""Minimal protobuf wire-format reader for Antigravity's conversation databases.

Antigravity (IDE and `agy` CLI) stores each conversation as a SQLite file whose rows hold
protobuf blobs. No .proto files ship with it, so the field numbers below were read from the
data (2026-10-26, agy 1.4.7). They match Codeium's ModelUsageStats layout:

    step metadata (steps.metadata)        usage stats (metadata field 9)
      1  created_at {1: seconds, 2: nanos}    1  model enum
      9  usage stats                          2  input tokens
     11  model enum                           3  output tokens (thinking + response)
                                              4  cache write tokens
    gen_metadata.data                         5  cache read tokens
      1.4   usage stats (same as above)       9  thinking tokens
      1.19  model id, e.g. gemini-3.8-flash  10  response tokens
      1.21  display name                     11  response id

    steps.step_payload for step_type 14 (user input): field 19 -> 2 holds the prompt text.
"""


def _varint(buf, i):
    result = shift = 0
    while True:
        if i >= len(buf):
            raise ValueError('truncated varint')
        byte = buf[i]
        i += 1
        result |= (byte & 0x7F) << shift
        shift += 7
        if byte < 0x80:
            return result, i
        if shift > 70:
            raise ValueError('varint too long')


def fields(buf):
    """Parse one message level into a list of (field_number, value). Length-delimited values
    stay as bytes; call fields() on them again to descend."""
    out, i = [], 0
    buf = bytes(buf or b'')
    while i < len(buf):
        key, i = _varint(buf, i)
        number, wire = key >> 3, key & 7
        if number == 0:
            raise ValueError('field 0')
        if wire == 0:
            value, i = _varint(buf, i)
        elif wire == 1:
            value, i = buf[i:i + 8], i + 8
        elif wire == 5:
            value, i = buf[i:i + 4], i + 4
        elif wire == 2:
            length, i = _varint(buf, i)
            if i + length > len(buf):
                raise ValueError('truncated bytes')
            value, i = buf[i:i + length], i + length
        else:
            raise ValueError(f'unsupported wire type {wire}')
        out.append((number, value))
    return out


def first(buf, *path):
    """Follow field numbers through nested messages and return the first match, or None."""
    value = buf
    for number in path:
        try:
            parsed = fields(value)
        except (ValueError, TypeError):
            return None
        value = next((v for n, v in parsed if n == number), None)
        if value is None:
            return None
    return value


def text(value):
    if isinstance(value, (bytes, bytearray)):
        try:
            return bytes(value).decode('utf-8')
        except UnicodeDecodeError:
            return None
    return None


def usage(buf):
    """Decode a usage-stats message into token counts, or None if it carries no tokens."""
    try:
        parsed = dict((n, v) for n, v in fields(buf) if isinstance(v, int))
    except (ValueError, TypeError):
        return None
    input_tokens, output_tokens = parsed.get(2, 0), parsed.get(3, 0)
    if not input_tokens and not output_tokens:
        return None
    response_id = first(buf, 11)
    return {
        'model_enum': parsed.get(1),
        'input': input_tokens,
        'output': output_tokens,
        'cache_write': parsed.get(4, 0),
        'cache_read': parsed.get(5, 0),
        'reasoning': parsed.get(9, 0),
        'response_id': text(response_id),
    }
