"""Kiro CLI adapter (issue #57).

kiro-cli chat does not support stream-json output. This adapter runs
kiro-cli in --no-interactive mode, captures all stdout, and synthesizes
a result event from the text output.
"""
import signal
from adapters import AdapterBase


class KiroAdapter(AdapterBase):

    def build_cmd(self, prompt, model, max_turns, add_dirs):
        cmd = [
            'kiro-cli', 'chat',
            '--no-interactive',
            '--trust-all-tools',
            '--model', model,
        ]
        # kiro-cli takes the prompt as a positional argument
        cmd.append(prompt)
        return cmd

    def parse_event(self, line):
        """kiro-cli doesn't emit stream-json. Collect raw text lines and
        synthesize a single result event when the process ends."""
        line = line.rstrip('\n')
        if not line:
            return None
        # Return a synthetic text event — the dispatcher accumulates these
        return {'type': 'text', 'content': line}

    def extract_usage(self, event):
        # kiro-cli doesn't report per-event usage; return empty
        return {}

    def extract_result(self, event):
        # No native result event — dispatcher uses forced-result path
        return None

    def model_family(self, model):
        from calc_npt import detect_family
        return detect_family(model)

    def shutdown_signal(self):
        return signal.SIGTERM
