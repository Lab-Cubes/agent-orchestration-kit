#!/usr/bin/env python3
# validate_schema — validate a JSON instance against a JSON Schema draft-2020-12 document.
#
# Usage:
#   python3 validate_schema.py <schema-path> <instance-path>
#
# Exit codes:
#   0 — valid
#   1 — validation failed (errors printed to stderr)
#   2 — dependency missing or invocation error (jsonschema not installed, file not found, etc.)
#
# Requires the jsonschema package (draft-2020-12 support needs v4.18+):
#   pip install "jsonschema[format-nongpl]>=4.18"
#
# Reusable by cmd_decompose (#66) for schema-validation-at-ingest.
import sys

try:
    import jsonschema
    from jsonschema import validate, ValidationError
    import jsonschema.validators
except ImportError:
    print(
        "error: jsonschema package not found.\n"
        "Install with: pip install \"jsonschema[format-nongpl]>=4.18\"",
        file=sys.stderr,
    )
    sys.exit(2)

import json
import pathlib


def load_json(path: str) -> object:
    p = pathlib.Path(path)
    if not p.exists():
        print(f"error: file not found: {path}", file=sys.stderr)
        sys.exit(2)
    try:
        with p.open() as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        print(f"error: invalid JSON in {path}: {e}", file=sys.stderr)
        sys.exit(2)


def get_validator_class(schema: dict):
    """Return the appropriate jsonschema validator class for the schema's $schema URI."""
    schema_uri = schema.get("$schema", "")
    if "2020-12" in schema_uri:
        return jsonschema.Draft202012Validator
    if "2019-09" in schema_uri:
        return jsonschema.Draft201909Validator
    if "draft-07" in schema_uri:
        return jsonschema.Draft7Validator
    # Default to draft-2020-12 (our standard).
    return jsonschema.Draft202012Validator


def main():
    if len(sys.argv) != 3:
        print(
            "usage: validate_schema.py <schema-path> <instance-path>",
            file=sys.stderr,
        )
        sys.exit(2)

    schema_path, instance_path = sys.argv[1], sys.argv[2]

    schema = load_json(schema_path)
    instance = load_json(instance_path)

    validator_class = get_validator_class(schema)
    validator = validator_class(schema)

    errors = list(validator.iter_errors(instance))
    if not errors:
        sys.exit(0)

    print(
        f"validation failed: {instance_path} does not conform to {schema_path}",
        file=sys.stderr,
    )
    for err in errors:
        path = " -> ".join(str(p) for p in err.absolute_path) if err.absolute_path else "(root)"
        print(f"  [{path}] {err.message}", file=sys.stderr)
    sys.exit(1)


if __name__ == "__main__":
    main()
