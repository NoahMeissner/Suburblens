# @Noah Meissner 18.10.2026
"""The shared `rich` console for the dev-server's request/SQL logging.

web.app frames each request with a Rule (method + path, then status + timing);
web.db prints the SQL and row preview nested inside that frame. Both need to
write through the same Console so the two interleave correctly and share one
terminal width - hence this tiny module instead of each file making its own.
"""
from rich.console import Console

console = Console()
