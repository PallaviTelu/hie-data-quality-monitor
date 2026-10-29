"""
Run the monthly validation pipeline end to end.

Steps:
  1. Load raw CSVs into SQLite as all-TEXT tables (preserves the raw mess)
  2. Run the SQL files in sql/ in order
  3. Export Tableau-ready CSVs to data/clean/

Usage:  python scripts/run_pipeline.py
To process a new month: replace the files in data/raw/, then rerun.
"""
import csv
import sqlite3
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
RAW = ROOT / "data" / "raw"
CLEAN = ROOT / "data" / "clean"
SQL_DIR = ROOT / "sql"
DB_PATH = ROOT / "data" / "hie_monitor.db"

RAW_TABLES = {
    "raw_facilities": RAW / "facilities.csv",
    "raw_submissions": RAW / "monthly_submissions_raw.csv",
    "raw_errors": RAW / "validation_errors_raw.csv",
}

EXPORTS = {
    # output file: SQL query
    "monthly_summary.csv": "SELECT * FROM monthly_summary ORDER BY report_month",
    "facility_month_status.csv": "SELECT * FROM facility_month_status ORDER BY report_month, facility_id",
    "facility_status.csv": "SELECT * FROM facility_status ORDER BY facility_id",
    "error_by_type_month.csv": "SELECT * FROM error_by_type_month ORDER BY report_month, error_type",
    "error_by_facility_type.csv": "SELECT * FROM error_by_facility_type ORDER BY report_month, facility_type",
    "worst_offenders.csv": "SELECT * FROM worst_offenders ORDER BY offender_rank",
    "validation_summary.csv": "SELECT * FROM validation_summary ORDER BY check_id",
    "rejected_rows.csv": (
        "SELECT * FROM rejected_submissions UNION ALL SELECT * FROM rejected_errors "
        "ORDER BY source_table, reject_reason, raw_row_id"
    ),
}


def load_raw(conn):
    for table, path in RAW_TABLES.items():
        with open(path, newline="") as f:
            reader = csv.reader(f)
            header = next(reader)
            conn.execute(f"DROP TABLE IF EXISTS {table}")
            cols = ", ".join(f'"{c}" TEXT' for c in header)
            conn.execute(f"CREATE TABLE {table} ({cols})")
            placeholders = ", ".join("?" for _ in header)
            conn.executemany(f"INSERT INTO {table} VALUES ({placeholders})", reader)
        n = conn.execute(f"SELECT COUNT(*) FROM {table}").fetchone()[0]
        print(f"loaded {table}: {n} rows")


def run_sql_files(conn):
    for path in sorted(SQL_DIR.glob("*.sql")):
        print(f"running {path.name}")
        conn.executescript(path.read_text())


def export(conn):
    CLEAN.mkdir(parents=True, exist_ok=True)
    for filename, query in EXPORTS.items():
        cur = conn.execute(query)
        cols = [d[0] for d in cur.description]
        rows = cur.fetchall()
        with open(CLEAN / filename, "w", newline="") as f:
            w = csv.writer(f)
            w.writerow(cols)
            w.writerows(rows)
        print(f"exported {filename}: {len(rows)} rows")


def main():
    if DB_PATH.exists():
        DB_PATH.unlink()
    conn = sqlite3.connect(DB_PATH)
    try:
        load_raw(conn)
        run_sql_files(conn)
        conn.commit()
        export(conn)
    finally:
        conn.close()
    print("done")


if __name__ == "__main__":
    sys.exit(main())
