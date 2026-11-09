/* =====================================================================
   01_create_tables.sql  (PostgreSQL)  -  APSEZ (Adani Ports & SEZ) project

   BEFORE running this file:
     1. In pgAdmin: right-click "Databases" > Create > Database... > name: apsez_db > Save.
     2. Click apsez_db, then Tools > Query Tool, open this file and press F5 (Execute).
   Safe to re-run: it drops and recreates the tables.

   DIMENSIONS (who / what / when):  dim_quarter, dim_port, dim_segment
   FACTS (the numbers):             fact_consolidated, fact_segment, fact_port_volume,
                                    fact_market, fact_cluster, fact_port_financial
   ===================================================================== */

-- drop facts first, then dimensions (a table that is referenced cannot be dropped first)
DROP TABLE IF EXISTS fact_port_financial CASCADE;
DROP TABLE IF EXISTS fact_cluster        CASCADE;
DROP TABLE IF EXISTS fact_market         CASCADE;
DROP TABLE IF EXISTS fact_port_volume    CASCADE;
DROP TABLE IF EXISTS fact_segment        CASCADE;
DROP TABLE IF EXISTS fact_consolidated   CASCADE;
DROP TABLE IF EXISTS dim_segment         CASCADE;
DROP TABLE IF EXISTS dim_port            CASCADE;
DROP TABLE IF EXISTS dim_quarter         CASCADE;

/* ---------- DIMENSIONS ---------- */
CREATE TABLE dim_quarter (
    quarter_key     VARCHAR(8)   PRIMARY KEY,                      -- e.g. 'Q2 FY27'
    fiscal_year     CHAR(4)      NOT NULL,                         -- 'FY27' (FY ends 31 March)
    fiscal_quarter  SMALLINT     NOT NULL CHECK (fiscal_quarter BETWEEN 1 AND 4),
    period_end      DATE         NOT NULL,
    deck_url        VARCHAR(400)
);

CREATE TABLE dim_port (
    port    VARCHAR(40) PRIMARY KEY,
    scope   VARCHAR(15) NOT NULL CHECK (scope IN ('Domestic','International')),
    coast   VARCHAR(10)                                            -- West / South / East (domestic only)
);

CREATE TABLE dim_segment (
    segment        VARCHAR(40) PRIMARY KEY,
    segment_order  SMALLINT    NOT NULL
);

/* ---------- FACTS ---------- */
-- is_restated = 'Y' means a later deck restated an earlier quarter; the original row is kept.
-- UNIQUE (..., source_deck) allows only one row per quarter per deck, so duplicates are rejected.

CREATE TABLE fact_consolidated (
    id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quarter_key   VARCHAR(8)     NOT NULL REFERENCES dim_quarter(quarter_key),
    revenue_cr    NUMERIC(12,2)  NOT NULL,                         -- Rs crore
    ebitda_cr     NUMERIC(12,2)  NOT NULL,
    pbt_cr        NUMERIC(12,2),
    pat_cr        NUMERIC(12,2),
    is_restated   CHAR(1)        NOT NULL DEFAULT 'N' CHECK (is_restated IN ('Y','N')),
    source_deck   VARCHAR(8)     NOT NULL,
    source_slide  VARCHAR(10),
    notes         TEXT,
    CONSTRAINT uq_fact_consolidated UNIQUE (quarter_key, source_deck)
);

CREATE TABLE fact_segment (
    id                   INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quarter_key          VARCHAR(8)    NOT NULL REFERENCES dim_quarter(quarter_key),
    segment              VARCHAR(40)   NOT NULL REFERENCES dim_segment(segment),
    segment_as_reported  VARCHAR(60),
    revenue_cr           NUMERIC(12,2) NOT NULL,
    ebitda_cr            NUMERIC(12,2) NOT NULL,
    is_restated          CHAR(1)       NOT NULL DEFAULT 'N' CHECK (is_restated IN ('Y','N')),
    source_deck          VARCHAR(8)    NOT NULL,
    source_slide         VARCHAR(10),
    notes                TEXT,
    CONSTRAINT uq_fact_segment UNIQUE (quarter_key, segment, source_deck)
);

CREATE TABLE fact_port_volume (
    id                 INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quarter_key        VARCHAR(8)    NOT NULL REFERENCES dim_quarter(quarter_key),
    port               VARCHAR(40)   NOT NULL REFERENCES dim_port(port),
    total_mmt          NUMERIC(8,2)  NOT NULL,                     -- million metric tonnes
    coal_mmt           NUMERIC(8,2),
    other_dry_mmt      NUMERIC(8,2),
    container_000_teu  NUMERIC(12,1),                              -- '000 TEU
    container_mmt      NUMERIC(8,2),
    liquid_mmt         NUMERIC(8,2),
    is_restated        CHAR(1)       NOT NULL DEFAULT 'N' CHECK (is_restated IN ('Y','N')),
    source_deck        VARCHAR(8)    NOT NULL,
    source_slide       VARCHAR(10),
    notes              TEXT,
    CONSTRAINT uq_fact_port_volume UNIQUE (quarter_key, port, source_deck)
);

CREATE TABLE fact_market (
    id                        INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quarter_key               VARCHAR(8)    NOT NULL REFERENCES dim_quarter(quarter_key),
    domestic_mmt              NUMERIC(8,2),
    international_mmt         NUMERIC(8,2),
    apsez_total_mmt           NUMERIC(8,2),
    allindia_share            NUMERIC(6,4),                        -- 0.276 = 27.6%
    allindia_container_share  NUMERIC(6,4),
    west_coast_mmt            NUMERIC(8,2),
    south_coast_mmt           NUMERIC(8,2),
    east_coast_mmt            NUMERIC(8,2),
    mundra_mmt                NUMERIC(8,2),
    rail_container_teu        INTEGER,
    is_restated               CHAR(1)       NOT NULL DEFAULT 'N' CHECK (is_restated IN ('Y','N')),
    source_deck               VARCHAR(8)    NOT NULL,
    source_slide              VARCHAR(10),
    notes                     TEXT,
    CONSTRAINT uq_fact_market UNIQUE (quarter_key, source_deck)
);

CREATE TABLE fact_cluster (                                        -- cluster-wise domestic ports, from Q1 FY27
    id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quarter_key   VARCHAR(8)    NOT NULL REFERENCES dim_quarter(quarter_key),
    cluster       VARCHAR(30)   NOT NULL,
    revenue_cr    NUMERIC(12,2) NOT NULL,
    ebitda_cr     NUMERIC(12,2) NOT NULL,
    is_restated   CHAR(1)       NOT NULL DEFAULT 'N' CHECK (is_restated IN ('Y','N')),
    source_deck   VARCHAR(8)    NOT NULL,
    source_slide  VARCHAR(10),
    notes         TEXT,
    CONSTRAINT uq_fact_cluster UNIQUE (quarter_key, cluster, source_deck)
);

CREATE TABLE fact_port_financial (                                 -- key ports revenue/EBITDA, up to Q4 FY26
    id            INTEGER GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
    quarter_key   VARCHAR(8)    NOT NULL REFERENCES dim_quarter(quarter_key),
    entity        VARCHAR(30)   NOT NULL,
    revenue_cr    NUMERIC(12,2) NOT NULL,
    ebitda_cr     NUMERIC(12,2) NOT NULL,
    is_restated   CHAR(1)       NOT NULL DEFAULT 'N' CHECK (is_restated IN ('Y','N')),
    source_deck   VARCHAR(8)    NOT NULL,
    source_slide  VARCHAR(10),
    notes         TEXT,
    CONSTRAINT uq_fact_port_financial UNIQUE (quarter_key, entity, source_deck)
);


/* ---------- VIEW: latest segment figures ----------
   fact_segment can hold the same quarter+segment twice: the figure first reported (is_restated = 'N')
   and a later restated figure (is_restated = 'Y'). This view keeps ONE row per quarter+segment and
   lets the restated figure win. Always analyse from this view, not from the raw table.
   DISTINCT ON keeps the first row of each (quarter_key, segment) group after the ORDER BY. */
CREATE VIEW v_segment_latest AS
SELECT DISTINCT ON (quarter_key, segment)
       quarter_key, segment, revenue_cr, ebitda_cr, is_restated, source_deck
FROM fact_segment
ORDER BY quarter_key, segment, (is_restated = 'Y') DESC, id DESC;

SELECT 'Tables created. Now run 02_load_data.sql' AS message;
