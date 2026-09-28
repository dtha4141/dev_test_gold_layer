{% macro get_mart_config(mart_name) %}
    {% set registry = mart_registry() %}
    {% if mart_name not in registry %}
        {{ exceptions.raise_compiler_error(
            "Mart '" ~ mart_name ~ "' is not in mart_registry. Available marts: "
            ~ (registry.keys() | list | join(", "))
        ) }}
    {% endif %}
    {{ return(registry[mart_name]) }}
{% endmacro %}

{% macro get_mart_query(mart_name) %}
    {% set query_macro = context.get(mart_name) %}
    {% if query_macro is none %}
        {{ exceptions.raise_compiler_error(
            "No query macro found for '" ~ mart_name ~ "'. Create macros/mart_queries/"
            ~ mart_name ~ ".sql with a macro named " ~ mart_name ~ "()"
        ) }}
    {% endif %}
    {{ return(query_macro()) }}
{% endmacro %}