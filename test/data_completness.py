"""Checks that bronze row counts match the source files."""
# Noah Meissner 6.10.2026
import sys

import psycopg
from psycopg import sql

import paths
from pipeline.bronze.load import SOURCES


def count_file_rows(src) -> int:
    """Counts rows in the raw file – read like in the loader."""
    return len(src.read(src.path))


def count_db_rows(conn, table: str, source: str) -> int:
    """Counts rows in bronze.<table>, which originated from this file."""
    query = sql.SQL("SELECT count(*) FROM {} WHERE _source_file = %s").format(
        sql.Identifier("bronze", table)
    )
    return conn.execute(query, [source]).fetchone()[0]


def check_source(conn, name: str) -> bool:
    """Compares a source and prints a line; True = row count matches."""
    src = SOURCES[name]
    source = src.path.relative_to(paths.DATA_DIR).as_posix()
    label = f"bronze.{src.table}"

    if not src.path.exists():
        print(f"  {label:<32} Error  Data Missing: {src.path}")
        return False

    try:
        in_db = count_db_rows(conn, src.table, source)
    except psycopg.errors.UndefinedTable:
        print(f"  {label:<32} ERROR  Table missing – first python -m pipeline.run")
        return False

    in_file = count_file_rows(src)
    ok = in_file == in_db
    status = "OK" if ok else f"ERROR  ({in_db - in_file:+,} compared to the file)"
    print(f"  {label:<32} {in_db:>10,} / {in_file:>10,} rows  {status}")
    return ok


def run(selected: list[str] | None = None) -> bool:
    """Checks the selected sources (or all); True = all complete."""
    selected = selected or list(SOURCES)
    unknown = [name for name in selected if name not in SOURCES]
    if unknown:
        raise ValueError(f"Unknown Source: {', '.join(unknown)}. Allowed: {', '.join(SOURCES)}")

    print("Complete – all sources in the database:")
    with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
        results = [check_source(conn, name) for name in selected]

    failed = results.count(False)
    if failed:
        print(f"\n{failed} of {len(results)} sources incomplete.")
    else:
        print(f"\nAll {len(results)} sources complete.")
    return failed == 0


if __name__ == "__main__":
    sys.exit(0 if run(sys.argv[1:]) else 1)
