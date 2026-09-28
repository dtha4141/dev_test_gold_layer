{% macro eu_sales_credit_line_mart() %}
WITH
-- 01. Credit invoice lines — negative-amount credit lines (line_ext_amt < 0), itm_id/invn_trans_id required
credit_invoice_line AS (
    SELECT
      -- Business keys
        src_sys_cd,
        lgl_enty_cd,
        invc_id,
        sale_ordr_nbr,
        invn_trans_id,
        itm_id,
        src_cust_invc_trans_rec_id,
        sale_cmmsn_grp_id,
      -- Dates
        invc_dt,
      -- Amounts and quantities
        line_ext_amt,
        invc_catch_wgt_sale_uom_ext_val,
        invc_sale_uom_qty,
      -- Descriptive attributes
        rtn_rsn_cd,
        dlvr_cust_nm,
        sale_itm_desc,
        sale_uom_cd
    FROM `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.sale_invc_dtl_eu_fact`
    WHERE src_cust_invc_trans_del_ind <> 'Y'
      AND line_ext_amt < 0
      AND itm_id IS NOT NULL
      AND invn_trans_id IS NOT NULL
),

-- 02. Credit rebate keys — distinct keys to pre-filter rebate fact before aggregation
credit_rebate_keys AS (
    SELECT
        DISTINCT
      --Business keys
        src_sys_cd,
        lgl_enty_cd,
        invc_id,
        sale_ordr_nbr,
        invn_trans_id,
      --Item Attribute
        itm_id,
      --Dates
        invc_dt
    FROM credit_invoice_line
),

-- 03. Unified rebate amount — rebate pre-aggregated from Silver agr_acru_dtl_eu_fact, no D365/AX split
unified_rebate AS (
    SELECT
      --Business keys
        rb.src_sys_cd,
        rb.lgl_enty_cd,
        rb.invc_id,
        rb.sale_ordr_nbr,
        rb.invn_trans_id,
      --Item Atrribute
        rb.itm_id,
      --Dates
        rb.invc_dt,
        SUM(rb.acru_ext_amt)                            AS rbt_amt
    FROM `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.agr_acru_dtl_eu_fact` rb
    INNER JOIN credit_rebate_keys crk
        ON  rb.lgl_enty_cd   = crk.lgl_enty_cd
        AND rb.invc_id       = crk.invc_id
        AND rb.sale_ordr_nbr = crk.sale_ordr_nbr
        AND rb.invn_trans_id = crk.invn_trans_id
        AND rb.itm_id        = crk.itm_id
        AND rb.invc_dt       = crk.invc_dt
    GROUP BY
      rb.src_sys_cd,
      rb.lgl_enty_cd,
      rb.invc_id,
      rb.sale_ordr_nbr,
      rb.invn_trans_id,
      rb.itm_id,
      rb.invc_dt
),

-- 04. Employee master — deduped to one row per worker before joining, prevents fan-out
org_emple_hr_mstr AS (
    SELECT
        -- Record id
       src_wrk_rec_id,
       -- Employee name
      emple_frst_nm,
      emple_lst_nm
    FROM `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.org_emple_hr_mstr_eu_dim`
    WHERE src_wrk_del_ind <> 'Y'
    QUALIFY ROW_NUMBER() OVER (
    PARTITION BY src_wrk_rec_id
    ORDER BY src_wrk_mod_dttm DESC
    ) = 1
),

-- 05. Credit report base — self-joins to original order line, nets rebate, enriches attributes
credit_base AS (
    SELECT
      -- Business keys
        sl.src_sys_cd,
        sl.lgl_enty_cd,
        sl.invc_id,
        sl.sale_ordr_nbr,
        sl.invn_trans_id,
        sl.itm_id,
        sl.src_cust_invc_trans_rec_id                   AS src_invc_line_rec_id,
      -- Dates
        sl.invc_dt                                      AS crdt_invc_dt,
        slo.req_ship_dt                                 AS crdt_invc_req_ship_dt,
      -- Amounts
        sl.line_ext_amt                                 AS line_amt,
        COALESCE(ur.rbt_amt, 0)                         AS rbt_amt,
        sl.line_ext_amt
        - COALESCE(ur.rbt_amt, 0)                       AS sgn_crdt_line_amt,
      -- Linked-order and document attributes
        slc.sale_ordr_nbr                               AS telesales_ordr_no,
        slo.sale_ordr_nbr                               AS crdt_line_lnk_to_sale_ordr_nbr,
        slc.prc_comnt_txt                               AS crdt_intrl_comnt_txt,
      -- Uplift comment — source-specific gate mirroring the legacy report
        IF(
        (sl.src_sys_cd = 'AX'
            AND (soh.ordr_ent_typ_cd = 8
                OR (soh.ordr_ent_typ_cd = 9
                    AND COALESCE(sl.rtn_rsn_cd, '') <> '')))
        OR (sl.src_sys_cd = 'D365'
            AND soh.ordr_sts_cd = 4),
        doc.doc_note_txt,
        NULL
        )                                               AS crdt_uplift_comnt_txt,
        doc.src_doc_ref_rec_id                          AS doc_ref_rec_id,
      -- Customer, item and return attributes
        sl.rtn_rsn_cd,
        srr.rtn_rsn_desc,
        cd.cust_id,
        cd.cust_full_nm                                 AS cust_nm,
        sl.sale_itm_desc                                AS itm_nm,
        sl.sale_uom_cd,
      -- Sales representative
        csg.cmmsn_sale_grp_id                           AS sale_cmmsn_grp_id,
        csg.cmmsn_sale_grp_nm                           AS sale_cmmsn_grp_nm,
        CONCAT(
        COALESCE(mgr.emple_frst_nm, ''),
        '-',
        COALESCE(mgr.emple_lst_nm, '')
        )                                               AS ordr_resp_sysco_emple,
      -- Signed credit quantity
        COALESCE(
        NULLIF(sl.invc_catch_wgt_sale_uom_ext_val, 0),
        sl.invc_sale_uom_qty
        )                                               AS sgn_crdt_sale_uom_qty
    FROM credit_invoice_line sl
    LEFT JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.sale_ordr_dtl_eu_fact` slc
        ON  sl.invn_trans_id = slc.invn_trans_id
        AND sl.lgl_enty_cd   = slc.lgl_enty_cd
        AND slc.src_sale_line_del_ind <> 'Y'

    INNER JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.sale_ordr_dtl_eu_fact` slo
        ON  slc.invn_rtn_trans_id = slo.invn_trans_id
        AND slc.lgl_enty_cd       = slo.lgl_enty_cd
        AND slo.src_sale_line_del_ind <> 'Y'

    -- document reference — joined on src_doc_ref_rec_id per Silver team guidance
    LEFT JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.ref_doc_ref_eu_val` doc
        ON  slc.src_sale_line_rec_id = doc.src_doc_ref_rec_id
        AND sl.lgl_enty_cd           = doc.ref_lgl_enty_cd
        AND doc.src_doc_ref_del_ind <> 'Y'

    LEFT JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.sale_ordr_head_eu_fact` soh
        ON  sl.sale_ordr_nbr = soh.sale_ordr_nbr
        AND sl.lgl_enty_cd   = soh.lgl_enty_cd
        AND soh.src_sale_del_ind <> 'Y'

    LEFT JOIN org_emple_hr_mstr mgr
        ON  soh.ordr_resp_sysco_emple_rec_id = mgr.src_wrk_rec_id

    LEFT JOIN unified_rebate ur
        ON  sl.lgl_enty_cd   = ur.lgl_enty_cd
        AND sl.invc_id       = ur.invc_id
        AND sl.sale_ordr_nbr = ur.sale_ordr_nbr
        AND sl.invn_trans_id = ur.invn_trans_id
        AND sl.itm_id        = ur.itm_id
        AND sl.invc_dt       = ur.invc_dt

    -- inlined from former CTE 04 (sale_invc_head) — source of true cust_id
    LEFT JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.sale_invc_head_eu_fact` sih
        ON  sl.lgl_enty_cd   = sih.lgl_enty_cd
        AND sl.invc_id       = sih.invc_id
        AND sl.sale_ordr_nbr = sih.sale_ordr_nbr
        AND sl.invc_dt       = sih.invc_dt
        AND sih.src_cust_invc_jnl_del_ind <> 'Y'

    -- customer dimension — resolves cust_nm from Silver cust_eu_dim (replaces sl.dlvr_cust_nm)
    LEFT JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.cust_eu_dim` cd
        ON  sih.lgl_enty_cd  = cd.lgl_enty_cd
        AND sih.cust_id      = cd.cust_id
        AND src_cust_del_ind <> 'Y'

    -- inlined from former CTE 05 (sale_cmmsn_grp) — source of sale_cmmsn_grp_id / sale_cmmsn_grp_nm
    LEFT JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.sale_cmmsn_grp_eu_dim` csg
        ON  cd.lgl_enty_cd       = csg.lgl_enty_cd
        AND cd.cust_sale_grp_id  = csg.cmmsn_sale_grp_id
        AND csg.src_cmmsn_sale_grp_del_ind <> 'Y'

    -- inlined from former CTE 06 (sale_rtn_rsn) — lookup for rtn_rsn_desc
    LEFT JOIN `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.sale_rsn_cd_eu_val` srr
        ON  sl.lgl_enty_cd = srr.lgl_enty_cd
        AND sl.rtn_rsn_cd  = srr.rtn_rsn_cd
        AND srr.src_rtn_rsn_cd_del_ind <> 'Y'
),

-- 06. Fiscal calendar — resolves crdt_invc_req_ship_dt into fiscal year/week
fiscal_calendar AS (
    SELECT
        fisc_prd_typ_cd,
        wk_strt_dt,
        wk_end_dt,
        SAFE_CAST(REGEXP_EXTRACT(wk_nm, r'(\d+)') AS INT64) AS crdt_line_fisc_wk_nbr,
        COALESCE(
        SAFE_CAST(NULLIF(yr_nm, '') AS INT64),
        SAFE_CAST(NULLIF(yr_nm_ax, '') AS INT64),
        EXTRACT(YEAR FROM yr_end_dt)
        )                                                   AS crdt_line_fisc_yr_nbr
    FROM `syy-df-hub-gld-eu-q.shared_d365_fo_eu_curr_dmnsl.cal_fisc_wk_eu_dim`
    WHERE wk_strt_dt IS NOT NULL
)

-- Final select
SELECT

  -- Source and document identifiers
    cb.src_sys_cd,
    cb.lgl_enty_cd                                      AS lgl_enty_id,
    cb.invc_id,
    cb.sale_ordr_nbr,
    cb.invn_trans_id,
    cb.src_invc_line_rec_id,
    cb.doc_ref_rec_id,
    cb.crdt_line_lnk_to_sale_ordr_nbr,

  -- Customer information
    cb.cust_id,
    cb.cust_nm,
    CONCAT(
      cb.cust_id,
      '-',
      COALESCE(cb.cust_nm, '')    
      )                                                   AS fmt_cust_nm,

  -- Item information
    cb.itm_id,
    cb.itm_nm,
    cb.sale_uom_cd,
    CONCAT(
      cb.itm_id,
      '-',
      COALESCE(cb.itm_nm, '')
    )                                                   AS fmt_itm_nm,

  -- Sales representative information
    cb.sale_cmmsn_grp_id,
    cb.sale_cmmsn_grp_nm,
    CONCAT(
    COALESCE(cb.sale_cmmsn_grp_id, ''),
    '-',
    COALESCE(cb.sale_cmmsn_grp_nm, '')
    )                                                   AS fmt_sale_cmmsn_grp_nm,
    cb.ordr_resp_sysco_emple,

  -- Return information
    cb.rtn_rsn_cd,
    cb.rtn_rsn_desc,
    COALESCE(
    UPPER(CONCAT(cb.rtn_rsn_cd, '-', cb.rtn_rsn_desc)),
    'Null'
    )                                                   AS crdt_rtn_rsn_txt,

  -- Credit report dates and fiscal period
    cb.crdt_invc_dt,
    cb.crdt_invc_req_ship_dt,
    fisc.crdt_line_fisc_yr_nbr,
    fisc.crdt_line_fisc_wk_nbr,
    CONCAT(
    CAST(fisc.crdt_line_fisc_yr_nbr AS STRING),
    '-',
    LPAD(CAST(fisc.crdt_line_fisc_wk_nbr AS STRING), 2, '0')
    )                                                   AS crdt_line_fisc_yr_wk_cd,

  -- Comments
    cb.crdt_intrl_comnt_txt,
    cb.crdt_uplift_comnt_txt,

  -- Financial measures
    cb.sgn_crdt_sale_uom_qty,
    cb.sgn_crdt_line_amt,
    cb.line_amt                                         AS xcld_rbt_net_sale_line_amt,
    cb.rbt_amt                                          AS line_rbt_amt,

  -- Reporting flags and generated key
    IF(cb.doc_ref_rec_id IS NOT NULL, 'Y', 'N')         AS cdt_rpt_vld_ind,
    CONCAT(
    cb.src_sys_cd,
    '-',
    cb.lgl_enty_cd,
    '-',
    CAST(cb.src_invc_line_rec_id AS STRING)
    )                                                   AS sale_crdt_line_core_id

FROM credit_base cb
LEFT JOIN fiscal_calendar fisc
    ON fisc.fisc_prd_typ_cd = 1
    WHERE cb.crdt_invc_req_ship_dt BETWEEN fisc.wk_strt_dt AND fisc.wk_end_dt

{% endmacro %}