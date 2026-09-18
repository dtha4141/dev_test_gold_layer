import argparse
from pathlib import Path
from google.cloud import bigquery

def dump_query(sql: str, path: str = "debug_last_query.sql"):
    Path(path).write_text(sql)
    print(f"(Full query written to {path} for inspection)")

def load_query(path: str) -> str:
    text = Path(path).read_text()
    return text.strip().rstrip(";")


def build_null_check_sql(base_query: str, pk_cols: list[str]) -> str:
    count_exprs = ",\n    ".join(
        f"COUNTIF({col} IS NULL) AS null_count_{col}" for col in pk_cols
    )
    return f"""
WITH base_mart AS (
{base_query}
)
SELECT
    COUNT(*) AS total_rows,
    {count_exprs}
FROM base_mart
"""


def build_sample_rows_sql(base_query: str, col: str, limit: int) -> str:
    return f"""
WITH base_mart AS (
{base_query}
)
SELECT *
FROM base_mart
WHERE {col} IS NULL
LIMIT {limit}
"""


def main():
    parser = argparse.ArgumentParser(
        description="Check a Gold mart's primary key columns for NULLs before it's deployed."
    )
    parser.add_argument("--project", required=True, help="e.g. syy-df-hub-gld-eu-d or syy-df-hub-gld-eu-q")
    parser.add_argument("--query-file", required=True, help="Path to the .sql file with the mart's SELECT")
    parser.add_argument("--pk-cols", required=True, help="Comma-separated PK column names")
    parser.add_argument("--limit", type=int, default=50, help="Max offending rows to print per column")
    args = parser.parse_args()

    pk_cols = [c.strip() for c in args.pk_cols.split(",")]
    base_query = load_query(args.query_file)

    client = bigquery.Client(project=args.project)

    print(f"Checking PK columns {pk_cols} for NULLs...\n")
    count_sql = build_null_check_sql(base_query, pk_cols)
    dump_query(count_sql)
    count_row = list(client.query(count_sql).result())[0]

    total_rows = count_row["total_rows"]
    print(f"Total rows scanned: {total_rows}\n")

    any_nulls = False
    for col in pk_cols:
        null_count = count_row[f"null_count_{col}"]
        status = "FAIL" if null_count > 0 else "OK"
        print(f"[{status}] {col}: {null_count} NULL row(s)")
        if null_count > 0:
            any_nulls = True

    if not any_nulls:
        print("\nNo NULLs found in any primary key column.")
        return

    print("\n--- Offending rows ---")
    for col in pk_cols:
        null_count = count_row[f"null_count_{col}"]
        if null_count == 0:
            continue
        print(f"\nRows where {col} IS NULL (showing up to {args.limit}):")
        sample_sql = build_sample_rows_sql(base_query, col, args.limit)
        for row in client.query(sample_sql).result():
            print(dict(row))


if __name__ == "__main__":
    main()