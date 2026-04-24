"""Adapter base class for agent runtime dispatch (issue #57).

Each adapter wraps a specific agent CLI (Claude, Kiro, Codex, etc.) and
exposes a uniform spawn/shutdown interface so the dispatcher stays
runtime-agnostic.
"""
from abc import ABC, abstractmethod


class AdapterBase(ABC):
    """Abstract base for runtime adapters."""

    @abstractmethod
    def build_cmd(self, prompt, model, max_turns, add_dirs):
        """Return the subprocess command list for this runtime."""

    @abstractmethod
    def parse_event(self, line):
        """Parse a single stdout line into a dict or None (skip)."""

    @abstractmethod
    def extract_usage(self, event):
        """Extract native token usage dict from an event, or empty dict."""

    @abstractmethod
    def extract_result(self, event):
        """Extract result dict from a final result event, or None."""

    @abstractmethod
    def model_family(self, model):
        """Return the model family string for NPT rate lookup."""

    def shutdown_signal(self):
        """Signal to send for graceful shutdown. Override per runtime."""
        import signal
        return signal.SIGINT
