/* =====================================================================
   04_analysis_queries.sql (PostgreSQL)  -  APSEZ port performance analysis
   Business questions answered in SQL. Run each query on its own in pgAdmin.
   Prerequisite: 01_create_tables.sql and 02_load_data.sql have been run.
   Segment figures come from the view v_segment_latest, so restated numbers win.
   ===================================================================== */

-- Q1. What were each segment's revenue and EBITDA in the latest quarter (Q2 FY27)?
SELECT segment, revenue_cr, ebitda_cr
FROM v_segment_latest
WHERE quarter_key = 'Q2 FY27';

-- Q2. Which segment grew revenue fastest between Q1 FY26 and Q2 FY27?
--     CTE 1 builds revenue and EBITDA margin per segment per quarter; CTE 2 compares the two quarters;
--     DENSE_RANK ranks segments by growth.
--     Caveats: the two quarters are five quarters apart (year-on-year is the usual comparison), International
--     growth includes the NQXT Australia consolidation (from Q4 FY26), and SEZ revenue is lumpy,
--     so its negative growth is not meaningful.
WITH segment_quarterly AS (
    SELECT 
        d.period_end,
        v.quarter_key,
        v.segment,
        v.revenue_cr,
        v.ebitda_cr,
        ROUND(100.0 * v.ebitda_cr / NULLIF(v.revenue_cr, 0), 2) AS ebitda_margin_pct
    FROM v_segment_latest AS v
    JOIN dim_quarter AS d 
      ON v.quarter_key = d.quarter_key
),
segment_growth AS (
    SELECT 
        q1.segment,
        q1.revenue_cr AS q1_fy26_revenue,
        q2.revenue_cr AS q2_fy27_revenue,
        ROUND(100.0 * (q2.revenue_cr - q1.revenue_cr) / NULLIF(q1.revenue_cr, 0), 2) AS growth_pct
    FROM segment_quarterly AS q1
    JOIN segment_quarterly AS q2 
      ON q1.segment = q2.segment
    WHERE q1.quarter_key = 'Q1 FY26' 
      AND q2.quarter_key = 'Q2 FY27'
)
SELECT 
    segment,
    q1_fy26_revenue,
    q2_fy27_revenue,
    growth_pct,
    DENSE_RANK() OVER (ORDER BY growth_pct DESC) AS growth_rank
FROM segment_growth
ORDER BY growth_rank;

-- Q3. How is domestic cargo split across the West, South and East coast, and how dominant is Mundra?
--     Uses conditional aggregation (SUM + CASE). Port totals are summed from fact_port_volume, so Q2 FY27 shows
--     117.0 MMT versus 118 MMT reported (see README, data notes).
SELECT 
    v.quarter_key,
    d.period_end,
    -- Total domestic volume across all ports
    SUM(v.total_mmt) AS total_domestic_mmt,
    
    -- Coast breakdown using conditional SUM
    SUM(CASE WHEN p.coast = 'West' THEN v.total_mmt ELSE 0 END) AS west_coast_mmt,
    SUM(CASE WHEN p.coast = 'South' THEN v.total_mmt ELSE 0 END) AS south_coast_mmt,
    SUM(CASE WHEN p.coast = 'East' THEN v.total_mmt ELSE 0 END) AS east_coast_mmt,
    
    -- Mundra specific volume and share %
    SUM(CASE WHEN p.port = 'Mundra' THEN v.total_mmt ELSE 0 END) AS mundra_mmt,
    ROUND(
        100.0 * SUM(CASE WHEN p.port = 'Mundra' THEN v.total_mmt ELSE 0 END) 
        / NULLIF(SUM(v.total_mmt), 0), 2
    ) AS mundra_share_pct

FROM fact_port_volume AS v
JOIN dim_port AS p ON v.port = p.port
JOIN dim_quarter AS d ON v.quarter_key = d.quarter_key
WHERE p.scope = 'Domestic'
GROUP BY v.quarter_key, d.period_end
ORDER BY d.period_end;
