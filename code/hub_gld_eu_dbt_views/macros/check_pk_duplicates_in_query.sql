{% macro check_pk_duplicates_in_query(pk_columns, row_limit=50) %}

{% set base_query %}{{ mart_query() }}{% endset %}

{% set count_sql %}
with base_mart as (
    {{ base_query }}
),
pk_groups as (
    select
        {% for col in pk_columns %}
        {{ col }}{{ "," if not loop.last }}
        {% endfor %}
        , count(*) as row_count
    from base_mart
    group by
        {% for col in pk_columns %}
        {{ col }}{{ "," if not loop.last }}
        {% endfor %}
    having count(*) > 1
)
select count(*) as duplicate_key_count
from pk_groups
{% endset %}

{% if execute %}
    {% set results = run_query(count_sql) %}
    {% set dup_count = results.rows[0]['duplicate_key_count'] %}

    {% if dup_count == 0 %}
        {{ log("No duplicate primary key values found.", info=True) }}
    {% else %}
        {{ log("[FAIL] " ~ dup_count ~ " duplicate primary key combination(s) found.", info=True) }}

        {% set sample_sql %}
        with base_mart as (
            {{ base_query }}
        ),
        pk_groups as (
            select
                {% for col in pk_columns %}
                {{ col }}{{ "," if not loop.last }}
                {% endfor %}
                , count(*) as row_count
            from base_mart
            group by
                {% for col in pk_columns %}
                {{ col }}{{ "," if not loop.last }}
                {% endfor %}
            having count(*) > 1
        )
        select bm.*
        from base_mart bm
        inner join pk_groups dg
            on
            {% for col in pk_columns %}
            bm.{{ col }} = dg.{{ col }}{{ " and " if not loop.last }}
            {% endfor %}
        limit {{ row_limit }}
        {% endset %}

        {% set sample_results = run_query(sample_sql) %}
        {{ log("---- Sample rows sharing a duplicated primary key ----", info=True) }}
        {% for r in sample_results.rows %}
            {{ log(r.values() | join(" | "), info=True) }}
        {% endfor %}
    {% endif %}
{% endif %}

{% endmacro %}