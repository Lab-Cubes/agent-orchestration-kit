#!/usr/bin/env bats
# test_permissions.bats — persona-driven .claude/settings.json generation.
#
# Bug #4: every worker's settings.json was identical (blanket Read/Write/Edit/
# Bash allow), so researchers and critics could `git commit` to the scope
# repo — which is how researcher-02 landed a commit on the kit's main branch
# during session 003.
#
# Fix: parse the `## Permissions` section of each persona file at setup time
# and write a persona-specific settings.json. Researchers and critics deny
# the destructive git operations. Coders keep full capabilities — the
# worktree is their isolation boundary.

load 'helpers/build-kit-tree.bash'

setup() {
    KIT_TMPDIR="$(mktemp -d)"
    build_kit_tree "$KIT_TMPDIR"
}

teardown() {
    rm -rf "${KIT_TMPDIR:-}"
}

# Helper: extract a list of permission patterns (allow or deny) from a
# worker's settings.json via python. Emits one pattern per line on stdout.
_perm_list() {
    local settings="$1"
    local key="$2"  # "allow" or "deny"
    python3 -c "
import json, sys
d = json.load(open('$settings'))
for r in d.get('permissions', {}).get('$key', []):
    print(r)
"
}

# ---------------------------------------------------------------------------
# Researcher — destructive git operations must be denied. This is the
# motivating case: researcher-02 committed to main in session 003 because
# the worker had Bash and the default settings denied nothing.
# ---------------------------------------------------------------------------

@test "researcher settings.json denies destructive git operations" {
    run_spawner setup researcher-01 researcher

    local settings="$KIT_AGENTS/researcher-01/.claude/settings.json"
    [ -f "$settings" ]

    local deny
    deny=$(_perm_list "$settings" deny)

    echo "$deny" | grep -qF "Bash(git commit:*)"
    echo "$deny" | grep -qF "Bash(git push:*)"
}

@test "researcher settings.json still allows read + report-writing" {
    run_spawner setup researcher-01 researcher

    local settings="$KIT_AGENTS/researcher-01/.claude/settings.json"
    [ -f "$settings" ]

    local allow
    allow=$(_perm_list "$settings" allow)

    echo "$allow" | grep -qF "Read(*)"
    echo "$allow" | grep -qF "Write(**)"
    echo "$allow" | grep -q "Bash"
}

# ---------------------------------------------------------------------------
# Critic — same destructive-git deny. Critics review, they must not commit
# or push. Persona docs already say "never Edit or Write production files",
# but persona text isn't enforcement — settings.json is.
# ---------------------------------------------------------------------------

@test "critic settings.json denies destructive git operations" {
    run_spawner setup critic-01 critic

    local settings="$KIT_AGENTS/critic-01/.claude/settings.json"
    [ -f "$settings" ]

    local deny
    deny=$(_perm_list "$settings" deny)

    echo "$deny" | grep -qF "Bash(git commit:*)"
    echo "$deny" | grep -qF "Bash(git push:*)"
}

# ---------------------------------------------------------------------------
# Coder — full capabilities inside the worktree. The worktree is the
# isolation boundary, not permissions. A fresh coder setup must keep the
# full allow list and allow local commits, while still denying push by default.
# ---------------------------------------------------------------------------

@test "coder settings.json allows worktree capabilities but denies push" {
    run_spawner setup coder-01 coder

    local settings="$KIT_AGENTS/coder-01/.claude/settings.json"
    [ -f "$settings" ]

    local allow deny
    allow=$(_perm_list "$settings" allow)
    deny=$(_perm_list "$settings" deny)

    echo "$allow" | grep -qF "Read(*)"
    echo "$allow" | grep -qF "Write(**)"
    echo "$allow" | grep -qF "Edit(**)"
    echo "$allow" | grep -q "Bash"

    # Coders may commit locally. Push remains denied unless a task grants it.
    ! echo "$deny" | grep -qF "Bash(git commit:*)"
    echo "$deny" | grep -qF "Bash(git push:*)"
}
