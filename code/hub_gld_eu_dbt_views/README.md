## Gold Mart Data Quality Checks (Pre-Deployment)

Lightweight dbt macros that run basic data quality checks on a mart's SELECT query
**before it is deployed**. Nothing is built or changed in BigQuery. The checks only read
data, and you run them with `dbt run-operation`.

| Check | Macro | What it reports |
|---|---|---|
| Primary key NULLs | `check_pk_nulls_in_query` | Table with NULL count per key column, plus the offending rows |
| Primary key duplicates | `check_pk_duplicates_in_query` | Table of duplicated key combinations and how many times each repeats |

A third check (full-row duplicates across the whole mart) is planned.

### 1. Files you will touch

| File | Purpose | Edit it? |
|---|---|---|
| `macros/mart_registry.sql` | Lists each mart and its key columns | Yes, one entry per mart |
| `macros/mart_queries/<mart_name>.sql` | The mart's SELECT query, wrapped in a macro | Yes, one file per mart |
| `macros/mart_helpers.sql` | Looks up keys and queries by mart name | No |
| `macros/check_pk_nulls_in_query.sql` | NULL check | No |
| `macros/check_pk_duplicates_in_query.sql` | Duplicate check | No |

### 2. One-time setup

1. dbt is installed and `dbt debug` passes.
2. You are logged in to Google Cloud: `gcloud auth application-default login`
3. Open a terminal **in the dbt project root**, the folder that contains `dbt_project.yml`.

### 3. Add a mart (step by step)

**Step 1: Pick the mart name.** Use the exact mart name, lowercase with underscores,
for example `eu_sales_credit_line_mart`. The same name is used in three places
(see the rules below).

**Step 2: Register the keys.** Add an entry to `macros/mart_registry.sql`:

```sql
'eu_sales_credit_line_mart': {
    'null_keys': ['src_sys_cd', 'lgl_enty_cd', 'src_invc_line_rec_id'],
    'duplicate_keys': ['src_sys_cd', 'lgl_enty_cd', 'src_invc_line_rec_id']
},
```

- Separate entries with a comma.
- `null_keys` are the columns checked for NULLs.
- `duplicate_keys` are the columns that together should be unique.
- The two lists can be different.

**Step 3: Add the query.** Create `macros/mart_queries/eu_sales_credit_line_mart.sql`:

```sql
{% macro eu_sales_credit_line_mart() %}
WITH ...
SELECT ...
FROM `project.dataset.table`
{% endmacro %}
```

**Step 4: Run the checks** (see section 4).

### 4. Run the checks

Run one command per line. Do not use `\` to continue a line.

```powershell
dbt run-operation check_pk_nulls_in_query --args '{mart_name: eu_sales_credit_line_mart}'
dbt run-operation check_pk_duplicates_in_query --args '{mart_name: eu_sales_credit_line_mart}'
```

Optional arguments go in the same `--args`:

| Argument | Default | Meaning |
|---|---|---|
| `row_limit` | 50 | Max rows shown in the result tables |
| `all_columns` | false | Show every column for the offending rows, not just the keys |

```powershell
dbt run-operation check_pk_duplicates_in_query --args '{mart_name: eu_sales_credit_line_mart, all_columns: true, row_limit: 100}'
```

### 5. Reading the output

**NULL check:** a table with one row per key column.

```
| key_column           | null_rows | total_rows | status |
| src_sys_cd           |         0 |    812,340 | OK     |
| src_invc_line_rec_id |        12 |    812,340 | FAIL   |
RESULT: FAIL - NULLs found in: src_invc_line_rec_id
```

For each FAIL, a second table shows the rows where that key is NULL.

**Duplicate check:** `RESULT: PASS` means the key is unique. On failure you get a table of
the duplicated key values and `row_count`, worst first. Use `all_columns: true` to see the full
rows behind them.

### 6. Rules to avoid common mistakes

1. **Three names must be identical:** the key in `mart_registry.sql`, the file name in
   `mart_queries/`, and the macro name on line 1 of that file. A leftover name like
   `mart_query()` causes `No query macro found`.
2. **Close the macro.** The file must end with `{% endmacro %}`.
3. **The file must contain only the macro.** No stray text, terminal commands or notes
   outside or inside the SELECT. A pasted `Get-ChildItem` line once broke a query.
4. **Paste plain BigQuery SQL only.** Replace dbt Jinja such as `{{ ref() }}`,
   `{{ source() }}` and `{{ config() }}` with fully qualified table names
   (`` `project.dataset.table` ``).
5. **No trailing semicolon** at the end of the query.
6. **Key columns must exist in the query's final output.** Use the output column name, including
   any alias, exactly as it is spelled. `lgl_enty_cd` and `lgl_enty_id` are different columns.
7. **Copy the mart name, don't retype it.** `eu_sale_credit_line_mart` and
   `eu_sales_credit_line_mart` are different names.
8. **Run from the project root**, where `dbt_project.yml` is. Running from another folder gives
   profile or project errors.
9. **After changing the SELECT, run the checks again.** Results describe the query as it was
   when you ran them.

### 7. Troubleshooting

| Error | Cause and fix |
|---|---|
| `Mart '...' is not in mart_registry` | Name typo, or the mart was not added. The message lists the available marts. |
| `No query macro found for '...'` | Rule 1 or 2: check the file name, the macro name on line 1 and `{% endmacro %}`. |
| `'mart_query' is undefined` | Something still calls the old `mart_query()`. Remove any old `mart_query.sql` and `pk_columns.sql`. |
| BigQuery `Syntax error ... at [line:col]` | Rule 3, 4 or 5. The line number counts from the top of the wrapped query, so subtract about 6 lines to find the position in your file. |
| `Unrecognized name: <column>` | Rule 6: the key isn't in the query's output. |
| `Invalid value for '--profiles-dir'` | Run from the project root, or add `--profiles-dir .` |
| PowerShell errors on `--project ... \` | Use a single-line command. In PowerShell the continuation character is a backtick, not `\`. |
| `Unable to acquire impersonated credentials` | Your Google account needs the `roles/iam.serviceAccountTokenCreator` role on the service account in `profiles.yml`. Ask the project admin. |
| Warning about a quota project | Harmless. To silence it: `gcloud auth application-default set-quota-project <project-id>` |

### 8. Notes

- These checks are for **pre-deployment** use. Once a mart is deployed, use proper dbt tests
  (`not_null`, `unique` or `unique_grain`) in `schema.yml` instead.
- If you edit `profiles.yml` to work around a local auth problem, **do not commit that change.**
- Agree with the team before committing new files in `mart_queries/`, so the folder doesn't fill up
  with marts nobody is checking.