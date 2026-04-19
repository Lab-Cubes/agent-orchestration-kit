#!/usr/bin/env bats
# test_prereqs_docs.bats — audit findings H-1 and H-2
#
# H-1: bats is used in CONTRIBUTING.md but not listed in README.md Requirements.
# H-2: curl is used in plugins/discord/_post.sh but not documented as a
#      prerequisite in plugins/discord/README.md, and install.sh has no
#      runtime presence check.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../../.." && pwd)"

@test "H-1: README.md Requirements section lists bats" {
    grep -q 'bats' "$REPO_ROOT/README.md"
}

@test "H-2a: plugins/discord/README.md mentions curl as a prerequisite" {
    grep -qi 'curl' "$REPO_ROOT/plugins/discord/README.md"
}

@test "H-2b: plugins/discord/install.sh checks for curl at runtime" {
    grep -q 'command -v curl' "$REPO_ROOT/plugins/discord/install.sh"
}
