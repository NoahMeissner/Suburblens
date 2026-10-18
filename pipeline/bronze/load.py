"""Loads raw source files into the bronze layer tables."""
import json
import re
import sys
from pathlib import Path
from typing import Callable, NamedTuple
import pandas as pd
import psycopg
from psycopg import sql
import paths

# DataClass
class Source(NamedTuple):
    """A bronze source: which file lands via which SQL in which table."""
    sql_file: str
    table: str
    path: Path
    read: Callable[[Path], pd.DataFrame]
    drop: tuple[str, ...] = ()
    """Columns present in the file but deliberately not in the bronze table
    (snake_case, as after to_snake_case). Used for values that are derived
    rather than source data - those get built in silver instead."""

# Helper
def load_csv_data(file_path: Path) -> pd.DataFrame:
    """Reads a CSV unmodified: each column as text, empty fields as ''."""
    return pd.read_csv(
        file_path,
        dtype=str,
        keep_default_na=False,
        encoding="utf-8-sig",
    )

# Helper
def load_geojson_data(file_path: Path) -> pd.DataFrame:
    """Reads a GeoJSON-FeatureCollection: one Feature = one row.

    The columns are the keys from "properties" (lists/objects remain as JSON text
    standing, e.g., routes_served). Additionally, geometry_type and geometry are included – the
    geometry remains as a GeoJSON text to ensure lossless bronze storage.

    The file is read completely into memory (the largest is ~65 MB).
    """
    with file_path.open(encoding="utf-8") as fh:
        features = json.load(fh).get("features", [])

    rows = []
    for feature in features:
        geometry = feature.get("geometry") or {}
        row = {key: _as_text(value) for key, value in (feature.get("properties") or {}).items()}
        row["geometry_type"] = _as_text(geometry.get("type"))
        row["geometry"] = json.dumps(geometry, separators=(",", ":")) if geometry else ""
        rows.append(row)

    return pd.DataFrame(rows).fillna("")

# Helper
def to_snake_case(name: str) -> str:
    """PlanningPortalApplicationNumber -> planning_portal_application_number,
    AccompaniedByVPAFlag -> accompanied_by_vpa_flag. Already-lowercase names stay as they are."""
    name = re.sub(r"([A-Z]+)([A-Z][a-z])", r"\1_\2", name.strip())   # VPAFlag -> VPA_Flag
    name = re.sub(r"([a-z0-9])([A-Z])", r"\1_\2", name)               # ByVPA   -> By_VPA
    return name.lower()

# Helper
def _as_text(value) -> str:
    """Makes a value suitable for CSV/SQL: None -> '', lists/dicts/bools -> JSON, else str()."""
    if value is None:
        return ""
    if isinstance(value, (list, dict, bool)):
        return json.dumps(value, separators=(",", ":"), ensure_ascii=False)
    return str(value)

# All The Sources
SOURCES = {
    "traffic_volume": Source("01_traffic_volume.sql", "traffic_segment_hourly",
                             paths.TRAFFIC_SEGMENT_HOURLY_CSV, load_csv_data),
    "school_location": Source("06_school_location.sql", "school_location",
                              paths.SCHOOL_LOCATION_CSV, load_csv_data,
                              drop=("nearest_station_distance_m",
                                    "station_count_300m",
                                    "nearest_station_id",
                                    "station_match_status",
                                    "station_dataset",
                                    "support_classes")),
    "rent_data": Source("05_rent_data.sql", "rent_data",
                        paths.RENT_DATA_CSV, load_csv_data,
                        drop=("bedrooms",)),
    "property_sales": Source("04_property_sales.sql", "property_sales",
                             paths.PROPERTY_SALES_CSV, load_csv_data,
                             drop=("load_to",)),
    "bus_stops": Source("07_station_stops.sql", "bus_stops",
                        paths.BUS_STOPS_GEOJSON, load_geojson_data),
    "bus_routes": Source("07_station_stops.sql", "bus_routes",
                         paths.BUS_ROUTES_GEOJSON, load_geojson_data),
    "bus_graph_edges": Source("03_gfts_historical.sql", "bus_graph_edges",
                              paths.BUS_GRAPH_EDGES_GEOJSON, load_geojson_data),
    "da_applications": Source("02_da_applications.sql", "da_applications",
                              paths.DA_APPLICATIONS_CSV, load_csv_data),
}

# Write Single DataFrame to Bronze Layer
def write_to_bronze(conn, df: pd.DataFrame, src: Source, source: str, name: str) -> int:
    """Writes a DataFrame to bronze.<table>, with lineage in bronze.raw_record.

    Every row lands twice: once as a raw_record (source_file, source_row, the
    row's own payload as jsonb - lossless, pre-cast) and once as a typed
    bronze.<table> row carrying that raw_record's id. That is what lets Silver
    account for every raw row exactly once via the Hub/Satellite tables in
    02_lineage_vault.sql, without re-reading the source file.
    """
    # SQL Preparation, we add 2 Columns to show the source of the Data -> Linaege
    target = sql.Identifier("bronze", src.table)
    columns = sql.SQL(", ").join(
        sql.Identifier(c) for c in list(df.columns) + ["_source_file", "_raw_record_id"]
    )
    copy_sql = sql.SQL("COPY {} ({}) FROM STDIN").format(target, columns)

    # Start Transaction -> If not everything suceed nothing will be saved
    with conn.transaction():
        # If script runs twice no Duplication
        conn.execute(
            sql.SQL("DELETE FROM {} WHERE _source_file = %s").format(target), [source]
        )
        conn.execute("DELETE FROM bronze.raw_record WHERE source_file = %s", [source])
        # Data Metadata: Logging Data with Name and Rows
        conn.execute(
            """INSERT INTO bronze.ingest_file (source_file, source_name, row_count)
                    VALUES (%s, %s, %s)
               ON CONFLICT (source_file) DO UPDATE
                  SET row_count = EXCLUDED.row_count, loaded_at = now()""",
            [source, name, len(df)],
        )
        # Use Postgres Copy-Method
        with conn.cursor().copy(
            "COPY bronze.raw_record (source_file, source_row, payload) FROM STDIN"
        ) as copy:
            # Therefore every row becomes a json obj
            for i, row in enumerate(df.itertuples(index=False, name=None), start=1):
                payload = {c: (v if v != "" else None) for c, v in zip(df.columns, row)}
                # HERE into Postgres
                copy.write_row([source, i, json.dumps(payload, ensure_ascii=False)])
        # Get Now all the IDS from Database
        raw_ids = [r[0] for r in conn.execute(
            "SELECT raw_id FROM bronze.raw_record WHERE source_file = %s ORDER BY source_row",
            [source],
        ).fetchall()]
        # Now Load all the Data again to Save them with Types -> Not just text
        with conn.cursor().copy(copy_sql) as copy:
            for row, raw_id in zip(df.itertuples(index=False, name=None), raw_ids):
                values = [v if v != "" else None for v in row]   # '' -> NULL
                copy.write_row(values + [source, raw_id])
    return len(df)

# Main Method to call
def run(selected: list[str] | None = None) -> None:
    """Loads the selected sources (or all) into the bronze layer.

    Called by pipeline/run.py, but can also be called individually.
    """
    # We can as well just Select only part of the Data makes not much sense, but
    # It is variable
    selected = selected or list(SOURCES)
    # This just checks if the names provided exist
    unknown = [name for name in selected if name not in SOURCES]
    if unknown:
        raise ValueError(f"Unknown source: {', '.join(unknown)}. Allowed: {', '.join(SOURCES)}")
    # Here we connect with the Database
    with psycopg.connect(paths.postgres_dsn(), autocommit=True) as conn:
        # This we need to follow the data in the Database system and to reproduce bugs
        conn.execute((paths.BRONZE_SQL_DIR / "00_lineage.sql").read_text(encoding="utf-8"))
        # Create every bronze table and its indexes first, even for a one-source
        # run: deleting a file's raw_record rows checks all tables that point at
        # raw_record, and that check needs each table's _raw_record_id index.
        for sql_file in dict.fromkeys(src.sql_file for src in SOURCES.values()):
            conn.execute((paths.BRONZE_SQL_DIR / sql_file).read_text(encoding="utf-8"))
        for name in selected:
            src = SOURCES[name]
            source = src.path.relative_to(paths.DATA_DIR).as_posix()
            # Here we load specific one dataset, clean it and then we call the write funciton
            df = src.read(src.path)
            df.columns = [to_snake_case(c) for c in df.columns]
            df = df.drop(columns=list(src.drop), errors="ignore")
            rows = write_to_bronze(conn, df, src, source, name)
            print(f"  bronze.{src.table:<25} {rows:>10,} rows  <- {source}")


if __name__ == "__main__":
    run(sys.argv[1:])
