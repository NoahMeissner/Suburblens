"""Postgres connection handling with query logging for the web app."""
import logging
import time
from contextlib import contextmanager

import psycopg
from rich.padding import Padding
from rich.syntax import Syntax
from rich.table import Table

import paths
from web.log import console

POINT_M = "ST_Transform(ST_SetSRID(ST_MakePoint(%s, %s), 4326), 7856)"
"""A lon/lat parameter pair projected into EPSG:7856, the CRS every distance
in this project is measured in. Interpolated into queries rather than repeated,
because getting the argument order backwards (it is longitude FIRST) puts the
address in the wrong hemisphere and nothing complains."""

_PREVIEW_ROWS = 3
"""How many returned rows to print in full before collapsing the rest into a
"+n more" - enough to see the shape of the data without flooding the terminal
on a 700-row query."""

_HEAD_INDENT = (0, 0, 0, 3)
"""Left padding for a "SQL ... ms" / "-> n rows" line - just enough to read
as nested under the request's rule in web.app, not a top-level line itself."""

_BODY_INDENT = (0, 0, 0, 8)
"""Left padding for the SQL text and the row preview table, one level deeper
than their "SQL ... ms" / "-> n rows" header line."""

logger = logging.getLogger("suburblens.db")


def _sql(query, limit: int = 240) -> Syntax:
    """A query as the terminal shows it: whitespace collapsed to one line,
    long queries capped so one SQL statement never scrolls the request off
    screen, then syntax-highlighted."""
    text = query.decode() if isinstance(query, bytes) else str(query)
    text = " ".join(text.split())
    if len(text) > limit:
        text = text[:limit] + "…"
    return Syntax(text, "sql", theme="ansi_dark", background_color="default",
                  word_wrap=True)


def _preview_table(description, rows) -> Table:
    """The first _PREVIEW_ROWS rows as a real table, columns named from the
    cursor's own description - so the preview never drifts from the query."""
    table = Table(show_header=True, header_style="bold magenta",
                  box=None, pad_edge=False)
    names = [col.name for col in description] if description else \
        [str(i) for i in range(len(rows[0]))]
    for name in names:
        table.add_column(name, overflow="fold", max_width=32)
    for row in rows[:_PREVIEW_ROWS]:
        table.add_row(*("·" if v is None else str(v) for v in row))
    return table


class LoggingCursor(psycopg.Cursor):
    """A cursor that prints every query, how long it took, and a preview of
    what came back - so a recorded terminal shows the database doing the
    work, not just the page it produced."""

    def execute(self, query, params=None, **kwargs):
        start = time.perf_counter()
        result = super().execute(query, params, **kwargs)
        elapsed_ms = (time.perf_counter() - start) * 1000
        if logger.isEnabledFor(logging.INFO):
            speed = "green" if elapsed_ms < 20 else "yellow" if elapsed_ms < 100 else "red"
            console.print(Padding(
                f"[bold cyan]SQL[/]  [{speed}]{elapsed_ms:6.1f} ms[/]", _HEAD_INDENT))
            console.print(Padding(_sql(query), _BODY_INDENT))
            if params:
                console.print(Padding(f"[dim]params={params}[/]", _BODY_INDENT))
        return result

    def fetchall(self):
        rows = super().fetchall()
        if logger.isEnabledFor(logging.INFO):
            if not rows:
                console.print(Padding("[dim]-> 0 rows[/]", _HEAD_INDENT))
            else:
                more = len(rows) - _PREVIEW_ROWS
                tail = f", … (+{more} more)" if more > 0 else ""
                console.print(Padding(f"-> {len(rows)} row(s){tail}", _HEAD_INDENT))
                console.print(Padding(_preview_table(self.description, rows), _BODY_INDENT))
        return rows

    def fetchone(self):
        row = super().fetchone()
        if logger.isEnabledFor(logging.INFO):
            console.print(Padding(f"[dim]-> {row}[/]", _HEAD_INDENT))
        return row


@contextmanager
def postgres():
    """A read-only Postgres connection for one request."""
    with psycopg.connect(
        paths.postgres_dsn(), autocommit=True, cursor_factory=LoggingCursor,
    ) as conn:
        yield conn
