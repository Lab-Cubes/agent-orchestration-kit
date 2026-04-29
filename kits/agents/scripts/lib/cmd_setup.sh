cmd_setup() {
    local agent_id="$1"
    local agent_type="${2:-coder}"
    local agent_dir="$NPS_AGENTS_HOME/$agent_id"
    local persona_file="$PERSONAS_DIR/$agent_type.md"

    if [[ ! -f "$persona_file" ]]; then
        err "No persona template: $persona_file"
        err "Available types: $(ls "$PERSONAS_DIR/" 2>/dev/null | sed 's/\.md$//' | tr '\n' ' ')"
        exit 1
    fi

    log "Setting up worker: $agent_id (type: $agent_type)"

    mkdir -p "$agent_dir"/{inbox,active,done,blocked,.claude}

    # One Python pass: read persona + template from argv, do all substitutions,
    # write the assembled CLAUDE.md. Fixes (a) sed -i '' macOS-only issue and
    # (b) every Python-string-interpolation injection by passing all values
    # through argv (never parsed as Python code).
    local assembled="$agent_dir/CLAUDE.md"
    local settings_json="$agent_dir/.claude/settings.json"
    python3 - \
        "$persona_file" "$TEMPLATE" "$assembled" \
        "$agent_id" "$agent_type" \
        "${DEFAULT_MODEL}" "$ISSUER_DOMAIN" "$ISSUER" \
        "$settings_json" \
        <<'PYEOF'
import re, sys, json
persona_file, template_file, out_file, agent_id, agent_type, default_model, issuer_domain, issuer, settings_path = sys.argv[1:]

persona = open(persona_file).read()

def kv(key):
    m = re.search(r'^' + key + r':\s*(.+)', persona, re.M)
    return m.group(1).strip() if m else ''

def section(name):
    pattern = r'^## ' + re.escape(name) + r'\n(.*?)(?=^## |\Z)'
    m = re.search(pattern, persona, re.M | re.S)
    return m.group(1).strip() if m else ''

model = kv('MODEL') or default_model
capabilities = kv('CAPABILITIES') or 'nop:execute'
run_mode = kv('RUN_MODE') or 'single-shot'
default_scope = section('Default Scope')
tools_section = section('Tools Section')
agent_instructions = section('Agent Instructions')

subs = {
    '{{AGENT_ID}}':       agent_id,
    '{{AGENT_TYPE}}':     agent_type,
    '{{MODEL}}':          model,
    '{{ISSUER_DOMAIN}}':  issuer_domain,
    '{{ISSUER}}':         issuer,
    '{{CAPABILITIES}}':   capabilities,
    '{{INBOX_PATH}}':     './inbox/',
    '{{RUN_MODE}}':       run_mode,
    '{{DEFAULT_SCOPE}}':  default_scope,
    '{{TOOLS_SECTION}}':  tools_section,
    '{{AGENT_INSTRUCTIONS}}': agent_instructions,
}

content = open(template_file).read()
for placeholder, replacement in subs.items():
    content = content.replace(placeholder, replacement)

open(out_file, 'w').write(content)

# Parse ## Permissions section and write persona-specific settings.json
perm_block = section('Permissions')
allow, deny = [], []
current = None
for line in perm_block.split('\n'):
    stripped = line.strip()
    if stripped.lower().startswith('allow:'):
        current = allow
    elif stripped.lower().startswith('deny:'):
        current = deny
    elif stripped.startswith('- ') and current is not None:
        current.append(stripped[2:].strip())
open(settings_path, 'w').write(json.dumps({'permissions': {'allow': allow, 'deny': deny}}, indent=2) + '\n')
PYEOF

    log "Worker $agent_id ready at $agent_dir"
    log "Mailbox: inbox/ active/ done/ blocked/"
}

# --- dispatch ---
