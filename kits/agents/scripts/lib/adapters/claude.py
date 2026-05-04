"""Claude Code CLI adapter (issue #57)."""
from adapters import AdapterBase


class ClaudeAdapter(AdapterBase):

    def build_cmd(self, prompt, model, max_turns, add_dirs):
        return [
            'claude', '-p', prompt,
            '--model', model,
            '--permission-mode', 'dontAsk',
            '--allowedTools', 'Read,Edit,Write,Bash,Glob,Grep',
            '--setting-sources', 'project,local',
            '--max-turns', str(max_turns),
            '--output-format', 'stream-json',
        ] + add_dirs

    def parse_event(self, line):
        import json
        line = line.rstrip('\n')
        if not line:
            return None
        try:
            return json.loads(line)
        except json.JSONDecodeError:
            return None

    def extract_usage(self, event):
        if event.get('type') != 'assistant':
            return {}
        return (event.get('message') or {}).get('usage') or {}

    def extract_result(self, event):
        if event.get('type') != 'result':
            return None
        return {
            'result':             event.get('result', ''),
            'usage':              event.get('usage') or {},
            'num_turns':          event.get('num_turns', 0),
            'stop_reason':        event.get('subtype', 'end_turn'),
            'is_error':           event.get('is_error', False),
            'permission_denials': event.get('permission_denials') or [],
        }

    def model_family(self, model):
        from calc_cgn import detect_family
        return detect_family(model)
