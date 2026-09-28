{% macro check_pk_nulls_in_query(mart_name, row_limit=50, all_columns=false) %}

{% set pk_cols = get_mart_config(mart_name)['null_keys'] %}
{% set base_query %}{{ get_mart_query(mart_name) }}{% endset %}
{% set select_cols = ("*" if all_columns else (pk_cols | join(", "))) %}

{% set summary_sql %}
with base_mart as (
    {{ base_query }}
),
counts as (
    select
        count(*) as total_rows,
        {% for col in pk_cols %}
        countif({{ col }} is null) as null_count_{{ col }}{{ "," if not loop.last }}
        {% endfor %}
    from base_mart
)
select
    u.key_column,
    u.null_rows,
    c.total_rows,
    if(u.null_rows > 0, 'FAIL', 'OK') as status
from counts c,
unnest([
    {% for col in pk_cols %}
    struct('{{ col }}' as key_column, c.null_count_{{ col }} as null_rows){{ "," if not loop.last }}
    {% endfor %}
]) as u with offset as pos
order by pos
{% endset %}

{% if execute %}
    {% set summary = run_query(summary_sql) %}

    {{ log("", info=True) }}
    {{ log("PRIMARY KEY NULL CHECK: " ~ mart_name, info=True) }}
    {% do summary.print_table(max_rows=none, max_columns=none, max_column_width=40) %}

    {% set failed_columns = [] %}
    {% for r in summary.rows %}
        {% if r['status'] == 'FAIL' %}
            {% do failed_columns.append(r['key_column']) %}
        {% endif %}
    {% endfor %}

    {% if failed_columns | length == 0 %}
        {{ log("RESULT: PASS - no NULLs in any primary key column.", info=True) }}
    {% else %}
        {{ log("RESULT: FAIL - NULLs found in: " ~ (failed_columns | join(", ")), info=True) }}
        {% for col in failed_columns %}
            {% set sample_sql %}
                with base_mart as (
                    {{ base_query }}
                )
                select {{ select_cols }}
                from base_mart
                where {{ col }} is null
                limit {{ row_limit }}
            {% endset %}
            {% set sample = run_query(sample_sql) %}
            {{ log("", info=True) }}
            {{ log("Rows where " ~ col ~ " IS NULL (up to " ~ row_limit ~ "):", info=True) }}
            {% do sample.print_table(max_rows=none, max_columns=none, max_column_width=40) %}
        {% endfor %}
    {% endif %}
{% endif %}

{% endmacro %}