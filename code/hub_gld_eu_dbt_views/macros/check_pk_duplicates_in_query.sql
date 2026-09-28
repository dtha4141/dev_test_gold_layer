{% macro check_pk_duplicates_in_query(mart_name, row_limit=50, all_columns=false) %}

{% set pk_cols = get_mart_config(mart_name)['duplicate_keys'] %}
{% set base_query %}{{ get_mart_query(mart_name) }}{% endset %}
{% set key_list = pk_cols | join(", ") %}

{% set dup_sql %}
with base_mart as (
    {{ base_query }}
),
pk_groups as (
    select
        {{ key_list }},
        count(*) as row_count
    from base_mart
    group by {{ key_list }}
    having count(*) > 1
)
select
    *,
    count(*) over () as total_dup_keys
from pk_groups
order by row_count desc
limit {{ row_limit }}
{% endset %}

{% if execute %}
    {% set dups = run_query(dup_sql) %}

    {{ log("", info=True) }}
    {{ log("PRIMARY KEY DUPLICATE CHECK: " ~ mart_name, info=True) }}
    {{ log("Key columns: " ~ key_list, info=True) }}

    {% if dups.rows | length == 0 %}
        {{ log("RESULT: PASS - no duplicate primary key values.", info=True) }}
    {% else %}
        {{ log("RESULT: FAIL - " ~ dups.rows[0]['total_dup_keys'] ~ " duplicated key combination(s). Showing up to " ~ row_limit ~ ":", info=True) }}
        {% do dups.exclude(['total_dup_keys']).print_table(max_rows=none, max_columns=none, max_column_width=40) %}

        {% if all_columns %}
            {% set full_sql %}
            with base_mart as (
                {{ base_query }}
            ),
            pk_groups as (
                select {{ key_list }}, count(*) as row_count
                from base_mart
                group by {{ key_list }}
                having count(*) > 1
                order by row_count desc
                limit {{ row_limit }}
            )
            select bm.*
            from base_mart bm
            inner join pk_groups dg
                on
                {% for col in pk_cols %}
                bm.{{ col }} = dg.{{ col }}{{ " and " if not loop.last }}
                {% endfor %}
            order by {{ key_list }}
            {% endset %}
            {% set full_rows = run_query(full_sql) %}
            {{ log("", info=True) }}
            {{ log("Full rows for the duplicated keys above:", info=True) }}
            {% do full_rows.print_table(max_rows=none, max_columns=none, max_column_width=40) %}
        {% endif %}
    {% endif %}
{% endif %}

{% endmacro %}