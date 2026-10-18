"""Builds the silver layer tables from bronze data."""
import sys
from typing import NamedTuple
import psycopg
from psycopg import sql
import paths

# We can not do that simultaenously we need to define different Steps, therefore we have this here
class Step(NamedTuple):
    """One silver step: which SQL file runs, and which table to count after."""
    sql_file: str
    table: str | None
    """Table whose row count is printed. None for steps that only set things up."""

# Just how we define this
STEPS = {
    "extensions":      Step("00_extensions.sql", None),
    "quality":         Step("01_quality.sql", None),
    "lineage_vault":   Step("02_lineage_vault.sql", "sat_property_sales"),
    "bus_stop":        Step("10_bus_stop.sql", "bus_stop"),
    "hex_300m":        Step("11_hex_300m.sql", "hex_300m"),
    "bus_edge":        Step("12_bus_edge.sql", "bus_edge"),
    "edge_travel_time": Step("13_bus_edge_travel_time.sql", "bus_edge_travel_time"),
    "school":          Step("20_school.sql", "school"),
    "stop_school":     Step("21_bus_stop_school.sql", "bus_stop_school"),
    "da_application":  Step("30_da_application.sql", "da_application"),
    "da_hex":          Step("31_da_hex_300m.sql", "da_hex_300m"),
    "stop_da":         Step("32_bus_stop_da.sql", "bus_stop_da"),
    "street":          Step("40_street_locality.sql", "street_locality"),
    "property_sale":   Step("41_property_sale.sql", "property_sale"),
    "sales_hex":       Step("43_property_sales_hex_300m.sql", "property_sales_hex_300m"),
    "stop_sales":      Step("44_bus_stop_property_sales.sql", "bus_stop_property_sales"),
    "traffic_segment": Step("50_traffic_segment.sql", "traffic_segment"),
    "traffic_hourly":  Step("51_traffic_hourly.sql", "traffic_segment_hourly"),
    "traffic_daypart": Step("52_traffic_daypart.sql", "traffic_segment_daypart"),
    "stop_traffic":    Step("53_bus_stop_traffic.sql", "bus_stop_traffic"),
    "lga":             Step("60_lga.sql", "lga"),
    "rent_lga":        Step("61_rent_lga.sql", "rent_lga"),
    "route":           Step("62_route.sql", "route"),
    "stop_lga":        Step("63_bus_stop_lga.sql", "bus_stop_lga"),
    "rent":            Step("60_rent.sql", "rent_observation"),
    "stop_profile":    Step("90_bus_stop_profile.sql", "bus_stop_profile"),
}

# Helper
def count_rows(conn, table: str) -> int:
    """Row count of silver.<table>."""
    query = sql.SQL("SELECT count(*) FROM {}").format(sql.Identifier("silver", table))
    return conn.execute(query).fetchone()[0]

# Helper Just execute the sql Script
def run_step(conn, name: str) -> None:
    """Runs one step in its own transaction and prints what it produced."""
    step = STEPS[name]
    statements = (paths.SILVER_SQL_DIR / step.sql_file).read_text(encoding="utf-8")

    with conn.transaction():
        conn.execute(statements)

    if step.table is None:
        print(f"  silver.{name:<24} ok")
    else:
        print(f"  silver.{step.table:<24} {count_rows(conn, step.table):>10,} rows")

# Helper -> If you debug reset, alternative you can say ./start.sh reset
def reset(conn) -> None:
    """Drops the whole silver schema.
    re-ingest.
    """
    print("  dropping schema silver ...")
    conn.execute("DROP SCHEMA IF EXISTS silver CASCADE")

# Main Method to run the Silver Layer
def run(selected: list[str] | None = None) -> None:
    """Runs the selected steps (or all) in dependency order.

    Called by pipeline/run.py, but can also be called individually.
    """
    # Pretty much same like in bronze
    do_reset = bool(selected) and "--reset" in selected
    selected = [name for name in (selected or []) if not name.startswith("--")]

    unknown = [name for name in selected if name not in STEPS]
    if unknown:
        raise ValueError(
            f"Unknown step: {', '.join(unknown)}. Allowed: {', '.join(STEPS)}"
        )
    # dict order is the dependency order, so never trust the order given on the CLI
    order = [name for name in STEPS if not selected or name in selected]

    with psycopg.connect(paths.postgres_dsn()) as conn:
        if do_reset:
            reset(conn)
        if not selected:
            existing = conn.execute(
                "SELECT tablename FROM pg_tables WHERE schemaname='silver'"
                " AND tablename NOT IN ('dq_run','dq_result','dq_reject')"
            ).fetchall()
            if existing:
                targets = sql.SQL(',').join(sql.Identifier('silver', t[0]) for t in existing)
                # CASCADE also empties the gold tables with foreign keys into
                # silver (connects_edge, transit_segment, lga_comparison). They
                # are stale after a full silver refresh and gold rebuilds them.
                conn.execute(sql.SQL('TRUNCATE {} CASCADE').format(targets))
        for name in order:
            run_step(conn,name)

if __name__ == "__main__":
    run(sys.argv[1:])
