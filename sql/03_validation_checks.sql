/* =====================================================================
   03_validation_checks.sql (PostgreSQL)  -  prove the data loaded correctly
   Run each block separately (highlight it, then press F5 in pgAdmin's Query Tool).
   These are the same checks as the Excel 'Checks' sheet, now in SQL.
   ===================================================================== */

-- 1. Row counts. Expect: dim_quarter 12, dim_port 16, dim_segment 5,
--    fact_consolidated 6, fact_segment 31, fact_port_volume 80,
--    fact_market 6, fact_cluster 14, fact_port_financial 43
SELECT 'dim_quarter' AS table_name, COUNT(*) AS row_count FROM dim_quarter
UNION ALL SELECT 'dim_port',            COUNT(*) FROM dim_port
UNION ALL SELECT 'dim_segment',         COUNT(*) FROM dim_segment
UNION ALL SELECT 'fact_consolidated',   COUNT(*) FROM fact_consolidated
UNION ALL SELECT 'fact_segment',        COUNT(*) FROM fact_segment
UNION ALL SELECT 'fact_port_volume',    COUNT(*) FROM fact_port_volume
UNION ALL SELECT 'fact_market',         COUNT(*) FROM fact_market
UNION ALL SELECT 'fact_cluster',        COUNT(*) FROM fact_cluster
UNION ALL SELECT 'fact_port_financial', COUNT(*) FROM fact_port_financial;

-- 2. Segments must add up to the consolidated figures (gap should be 0, or 1 = rounding in the EBITDA of Q2/Q3 FY26).
--    Uses v_segment_latest so that a restated figure replaces the first-reported one (see Q1 FY26).
SELECT c.quarter_key,
       c.revenue_cr                       AS consolidated_revenue,
       s.seg_revenue,
       s.seg_revenue - c.revenue_cr       AS revenue_gap,
       c.ebitda_cr                        AS consolidated_ebitda,
       s.seg_ebitda,
       s.seg_ebitda - c.ebitda_cr         AS ebitda_gap
FROM fact_consolidated AS c
JOIN (SELECT quarter_key, SUM(revenue_cr) AS seg_revenue, SUM(ebitda_cr) AS seg_ebitda
      FROM v_segment_latest
      GROUP BY quarter_key) AS s
  ON s.quarter_key = c.quarter_key
WHERE c.is_restated = 'N'
ORDER BY c.quarter_key;

-- 2b. Same check using ONLY first-reported figures: Q1 FY26 shows the gap (63 revenue / 57 EBITDA) that the restatement fixes.
SELECT c.quarter_key, s.seg_revenue - c.revenue_cr AS revenue_gap_as_reported, s.seg_ebitda - c.ebitda_cr AS ebitda_gap_as_reported
FROM fact_consolidated AS c
JOIN (SELECT quarter_key, SUM(revenue_cr) AS seg_revenue, SUM(ebitda_cr) AS seg_ebitda
      FROM fact_segment WHERE is_restated = 'N' GROUP BY quarter_key) AS s
  ON s.quarter_key = c.quarter_key
WHERE c.is_restated = 'N'
ORDER BY c.quarter_key;

-- 3. Domestic port volumes must add up to the reported domestic total.
--    Small gaps (<= 0.15) are rounding. A gap of 1.0 means a data-entry problem to find in the deck.
SELECT m.quarter_key,
       p.port_sum_mmt,
       m.domestic_mmt          AS reported_domestic_mmt,
       p.port_sum_mmt - m.domestic_mmt AS gap_mmt
FROM fact_market AS m
JOIN (SELECT v.quarter_key, SUM(v.total_mmt) AS port_sum_mmt
      FROM fact_port_volume AS v
      JOIN dim_port AS d ON d.port = v.port
      WHERE d.scope = 'Domestic' AND v.is_restated = 'N'
      GROUP BY v.quarter_key) AS p
  ON p.quarter_key = m.quarter_key
WHERE m.is_restated = 'N'
ORDER BY m.quarter_key;

-- 4. West + South + East coast must equal domestic volume (tolerance 1 MMT: Q2 FY27 deck rounds to whole numbers)
SELECT quarter_key,
       west_coast_mmt + south_coast_mmt + east_coast_mmt AS coast_sum_mmt,
       domestic_mmt,
       west_coast_mmt + south_coast_mmt + east_coast_mmt - domestic_mmt AS gap_mmt
FROM fact_market
WHERE is_restated = 'N'
ORDER BY quarter_key;

-- 5. Ports where coal + other dry + container + liquid differs from the total by more than rounding (0.15)
WITH comp AS (
    SELECT quarter_key, port, total_mmt,
           COALESCE(coal_mmt,0) + COALESCE(other_dry_mmt,0) + COALESCE(container_mmt,0) + COALESCE(liquid_mmt,0) AS component_sum,
           CASE WHEN coal_mmt IS NULL AND other_dry_mmt IS NULL
                 AND container_mmt IS NULL AND liquid_mmt IS NULL THEN 0 ELSE 1 END AS has_components
    FROM fact_port_volume
)
SELECT quarter_key, port, total_mmt, component_sum, component_sum - total_mmt AS gap_mmt
FROM comp
WHERE has_components = 1 AND ABS(component_sum - total_mmt) > 0.15
ORDER BY quarter_key, port;

-- 6. Cluster revenue/EBITDA must add up to the Domestic ports segment (from Q1 FY27)
SELECT k.quarter_key,
       k.cluster_revenue, s.revenue_cr AS domestic_segment_revenue, k.cluster_revenue - s.revenue_cr AS revenue_gap,
       k.cluster_ebitda,  s.ebitda_cr  AS domestic_segment_ebitda,  k.cluster_ebitda  - s.ebitda_cr  AS ebitda_gap
FROM (SELECT quarter_key, SUM(revenue_cr) AS cluster_revenue, SUM(ebitda_cr) AS cluster_ebitda
      FROM fact_cluster WHERE is_restated = 'N' GROUP BY quarter_key) AS k
JOIN fact_segment AS s
  ON s.quarter_key = k.quarter_key AND s.segment = 'Domestic ports' AND s.is_restated = 'N'
ORDER BY k.quarter_key;
