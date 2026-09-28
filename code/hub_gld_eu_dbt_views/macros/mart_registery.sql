{% macro mart_registry() %}

{% set registry = {
    'eu_sales_credit_line_mart': {
        'null_keys': ['src_sys_cd', 'lgl_enty_id', 'src_invc_line_rec_id'],
        'duplicate_keys': ['src_sys_cd', 'lgl_enty_id', 'src_invc_line_rec_id']
    },
    'eu_sales_invoice_line_mart': {
        'null_keys': ['col1', 'col2'],
        'duplicate_keys': ['col1', 'col2']
    }
} %}

{{ return(registry) }}

{% endmacro %}