{% macro check_pk_nulls_in_query(pk_columns, row_limit=50) %}

{% set base_query %}{{ mart_query() }}{% endset %}

{% set count_sql %}
with base_mart as (
    {{ base_query }}
)
select
    count(*) as total_rows,
    {% for col in pk_columns %}
    countif({{ col }} is null) as null_count_{{ col }}{{ "," if not loop.last }}
    {% endfor %}
from base_mart
{% endset %}

{% if execute %}
    {% set results = run_query(count_sql) %}
    {% set row = results.rows[0] %}
    {{ log("Total rows scanned: " ~ row['total_rows'], info=True) }}

    {% set failed_columns = [] %}
    {% for col in pk_columns %}
        {% set null_count = row['null_count_' ~ col] %}
        {% if null_count > 0 %}
            {{ log("[FAIL] " ~ col ~ ": " ~ null_count ~ " NULL row(s)", info=True) }}
            {% do failed_columns.append(col) %}
        {% else %}
            {{ log("[OK] " ~ col ~ ": 0 NULL rows", info=True) }}
        {% endif %}
    {% endfor %}

    {% if failed_columns | length == 0 %}
        {{ log("No NULLs found in any primary key column.", info=True) }}
    {% else %}
        {% for col in failed_columns %}
            {% set sample_sql %}
                with base_mart as (
                    {{ base_query }}
                )
                select *
                from base_mart
                where {{ col }} is null
                limit {{ row_limit }}
            {% endset %}
            {% set sample_results = run_query(sample_sql) %}
            {{ log("---- Rows where " ~ col ~ " IS NULL ----", info=True) }}
            {% for r in sample_results.rows %}
                {{ log(r.values() | join(" | "), info=True) }}
            {% endfor %}
        {% endfor %}
    {% endif %}
{% endif %}

{% endmacro %}