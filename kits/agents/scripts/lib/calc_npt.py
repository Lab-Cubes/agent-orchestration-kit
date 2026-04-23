#!/usr/bin/env python3
# calc_npt — convert raw usage dict to NPT (NPS-0 §4.3).
# Usage: from calc_npt import calc_npt, detect_family
import math

MODEL_FAMILY_ALIASES = {
    'claude': 'claude',
    'sonnet': 'claude',
    'haiku': 'claude',
    'opus': 'claude',
    'claude-sonnet-4-6': 'claude',
    'claude-haiku-4-5': 'claude',
    'claude-opus-4-7': 'claude',
}


def detect_family(model: str) -> str:
    m = model.lower()
    if m in MODEL_FAMILY_ALIASES:
        return MODEL_FAMILY_ALIASES[m]
    for key, fam in MODEL_FAMILY_ALIASES.items():
        if key in m:
            return fam
    return 'unknown'


def calc_npt(usage: dict, model_family: str, rates: dict) -> int:
    total = (
        (usage.get('input_tokens') or 0)
        + (usage.get('output_tokens') or 0)
        + (usage.get('cache_read_input_tokens') or 0)
        + (usage.get('cache_creation_input_tokens') or 0)
    )
    rate = rates.get(model_family, rates.get('unknown', 1.0))
    return math.ceil(total * rate)
