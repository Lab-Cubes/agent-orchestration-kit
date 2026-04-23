#!/usr/bin/env python3
# Validate kits/agents/config.json.
# Usage: validate_config.py <path>
# Exits 0 on success; exits 1 and prints errors to stderr on failure.
import json, sys


def _check_positive_int(config, key, errors):
    val = config.get(key)
    if val is None:
        return
    if not isinstance(val, int) or isinstance(val, bool) or val < 1:
        errors.append(f"'{key}' must be a positive integer")


def validate(config):
    errors = []

    for key in ('issuer_domain', 'issuer_agent_id'):
        val = config.get(key)
        if not isinstance(val, str) or not val:
            errors.append(f"'{key}' must be a non-empty string")

    _check_positive_int(config, 'default_budget_npt', errors)
    _check_positive_int(config, 'default_time_limit_s', errors)
    _check_positive_int(config, 'default_max_turns', errors)

    cbn = config.get('category_budget_npt')
    if cbn is not None:
        if not isinstance(cbn, dict):
            errors.append("'category_budget_npt' must be a dict")
        else:
            for cat, val in cbn.items():
                if cat.startswith('$'):
                    continue
                if not isinstance(val, int) or isinstance(val, bool) or val < 1:
                    errors.append(f"'category_budget_npt.{cat}' must be a positive integer")

    scr = config.get('default_soft_cap_ratio')
    if scr is not None:
        if not isinstance(scr, (int, float)) or isinstance(scr, bool) or scr <= 0 or scr > 1.0:
            errors.append("'default_soft_cap_ratio' must be a number in (0, 1.0]")

    rates = config.get('npt_exchange_rates')
    if rates is not None:
        if not isinstance(rates, dict):
            errors.append("'npt_exchange_rates' must be a dict")
        else:
            for family, val in rates.items():
                if family.startswith('$'):
                    continue
                if not isinstance(val, (int, float)) or isinstance(val, bool) or val < 0:
                    errors.append(f"'npt_exchange_rates.{family}' must be a non-negative number")

    return errors


if __name__ == '__main__':
    path = sys.argv[1]
    try:
        config = json.load(open(path))
    except (FileNotFoundError, json.JSONDecodeError) as e:
        print(f"config error: {e}", file=sys.stderr)
        sys.exit(1)

    errors = validate(config)
    if errors:
        print(f"config validation failed ({len(errors)} errors):", file=sys.stderr)
        for e in errors:
            print(f"  - {e}", file=sys.stderr)
        sys.exit(1)
    sys.exit(0)
