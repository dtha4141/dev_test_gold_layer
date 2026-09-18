## Gold Mart Data Quality Checks (Pre-Deployment)

These are lightweight dbt macros for running basic data quality checks against a mart's
SELECT query **before** it's deployed as a view. No model build required — these run
standalone via `dbt run-operation`.

Currently covers:
- Primary key NULL checks
- Primary key duplicate checks

### 1. Prerequisites

- dbt installed and working (`dbt debug` passes)
- Authenticated with `gcloud` (`gcloud auth application-default login`)
- Run all commands from the dbt project root (where `dbt_project.yml` lives)

### 2. Point the checks at your mart

Open `macros/mart_query.sql` and paste in the mart's SELECT query (no trailing semicolon):

```sql
{% macro mart_query() %}
select
    ...
from ...
{% endmacro %}
```

This is the **only file you need to edit** when switching between marts — both test
macros below read from it automatically.

### 3. Run the NULL check

```bash
dbt run-operation check_pk_nulls_in_query --args '{pk_columns: ["col1", "col2", "col3"]}'
```

Replace `pk_columns` with your mart's actual primary key column(s).

**Reading the output:**
- `[OK] col: 0 NULL rows` → that column is clean
- `[FAIL] col: N NULL row(s)` → sample offending rows are printed below

### 4. Run the duplicate key check

```bash
dbt run-operation check_pk_duplicates_in_query --args '{pk_columns: ["col1", "col2", "col3"]}'
```

**Reading the output:**
- `No duplicate primary key values found.` → PK is unique
- `[FAIL] N duplicate primary key combination(s) found.` → sample rows sharing a
  duplicated key are printed below
