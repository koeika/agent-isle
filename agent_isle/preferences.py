"""Shared local monitor preferences. No settings are applied to other apps."""
import json
from pathlib import Path

DEFAULT_SOURCES = frozenset(('codex', 'claude'))
SOURCES = frozenset(('codex', 'claude', 'cursor'))


def enabled_sources(state, fallback=DEFAULT_SOURCES):
    try:
        value = json.loads((Path(state) / 'preferences.json').read_text()).get('enabledProviders')
        if value is None: return set(DEFAULT_SOURCES)
        if not isinstance(value, list): return set(fallback)
        return {p for p in value if isinstance(p, str) and p in SOURCES}
    except FileNotFoundError:
        return set(DEFAULT_SOURCES)
    except (OSError, ValueError, TypeError, AttributeError):
        return set(fallback)


def read_receipts(state):
    try:
        value = json.loads((Path(state) / 'read-receipts.json').read_text())
        return value if isinstance(value, dict) else {}
    except (OSError, ValueError, TypeError):
        return {}
