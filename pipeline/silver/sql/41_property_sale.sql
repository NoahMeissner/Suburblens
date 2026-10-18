-- silver.property_sale - one row per deduplicated parcel-sale.

CREATE TABLE IF NOT EXISTS silver.property_sale (
    dealing_number          text        NOT NULL,
    parcel_seq              smallint    NOT NULL,
    property_id             integer,
    district_code           smallint,
    district_name           text,
    contract_date           date,
    settlement_date         date,
    contract_year           smallint,
    contract_quarter        text,                     -- '2024Q1'
    purchase_price          bigint,
    area_m2                 numeric(16,4),            -- m2 (already normalised upstream)
    area_type_source        text,                     -- 'M' | 'H', as published
    price_per_m2            numeric(16,2),
    property_type           text        NOT NULL,     -- house|unit|land|other
    nature_of_property      text,
    zoning                  text,
    strata_lot_number       integer,
    address_label           text,
    locality                text,
    postcode                text,
    lotidstring             text,                     -- DCDB parcel key
    street_id               text        REFERENCES silver.street_locality,
    geom                    geometry(Point, 4326),    -- Tier B
    geom_m                  geometry(Point, 7856),
    hex_id                  text,
    geocode_level           text        NOT NULL,     -- none|street|parcel
    is_standard_sale        boolean     NOT NULL,
    flag_price_outlier      boolean     NOT NULL DEFAULT false,
    flag_no_contract_date   boolean     NOT NULL DEFAULT false,
    flag_period_incomplete  boolean     NOT NULL DEFAULT false,
    flag_bad_date           boolean     NOT NULL DEFAULT false,
    flag_coarse_geocode     boolean     NOT NULL DEFAULT false,
    is_usable               boolean     NOT NULL DEFAULT true,
    record_source           text        NOT NULL DEFAULT 'NSW_VG_PROPERTY_SALES',
    loaded_at               timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT property_sale_pkey PRIMARY KEY (dealing_number, parcel_seq),
    CONSTRAINT property_sale_geocode_level_check
        CHECK (geocode_level IN ('none', 'street', 'parcel')),
    CONSTRAINT property_sale_type_check
        CHECK (property_type IN ('house', 'unit', 'land', 'other'))
);

-- Index street_id and contract_date, the two columns every mart joins/filters on
CREATE INDEX IF NOT EXISTS property_sale_street_idx   ON silver.property_sale (street_id);
CREATE INDEX IF NOT EXISTS property_sale_contract_idx ON silver.property_sale (contract_date);
-- Partial index: only usable sales are counted in the yearly breakdowns
CREATE INDEX IF NOT EXISTS property_sale_usable_idx   ON silver.property_sale (contract_year) WHERE is_usable;

INSERT INTO silver.property_sale AS t
    (dealing_number, parcel_seq, property_id, district_code, district_name,
     contract_date, settlement_date, contract_year, contract_quarter,
     purchase_price, area_m2, area_type_source, price_per_m2, property_type,
     nature_of_property, zoning, strata_lot_number, address_label, locality,
     postcode, lotidstring, street_id, geocode_level, is_standard_sale,
     flag_price_outlier, flag_no_contract_date, flag_period_incomplete,
     flag_bad_date, is_usable)
-- deduped: per Dealing+Parcel only the newest version stays (highest version_no,
-- after newest last_seen), and therefore we can guess  property_type .
WITH deduped AS (
    SELECT DISTINCT ON (b.dealing_number, b.parcel_seq)
           b.*,
           -- already m2 upstream (see the header note); only drop non-areas
           CASE WHEN b.area_m2 IS NULL OR b.area_m2 <= 0 THEN NULL
                ELSE b.area_m2 END                               AS area_norm_m2,
           CASE WHEN b.nature_of_property = 'R' AND b.strata_lot_number IS NOT NULL
                     THEN 'unit'
                WHEN b.nature_of_property = 'R' THEN 'house'
                WHEN b.nature_of_property = 'V' THEN 'land'
                ELSE 'other' END                                 AS property_type
      FROM bronze.property_sales b
     WHERE b.dealing_number IS NOT NULL
       AND b.parcel_seq     IS NOT NULL
     ORDER BY b.dealing_number, b.parcel_seq,
              b.version_no DESC NULLS LAST,          -- newest version wins
              b.last_seen  DESC NULLS LAST,
              b._row_id    DESC
),
-- priced: price_per_m2 calculation, only with wenn Fläche und Preis beide sinnvoll when price and space are reasonables
priced AS (
    SELECT d.*,
           CASE WHEN d.area_norm_m2 > 0 AND d.purchase_price > 0
                THEN round(d.purchase_price::numeric / d.area_norm_m2, 2) END AS price_per_m2
      FROM deduped d
),
-- bounds: 0.5%/99.5%-Perzentile for the price and 1%/99% for the price per m² as
-- outlier boundary, only over "Standard"-sellings calculated.
bounds AS (
    SELECT percentile_cont(0.005) WITHIN GROUP (ORDER BY purchase_price) AS p_lo,
           percentile_cont(0.995) WITHIN GROUP (ORDER BY purchase_price) AS p_hi,
           percentile_cont(0.01)  WITHIN GROUP (ORDER BY price_per_m2)   AS m2_lo,
           percentile_cont(0.99)  WITHIN GROUP (ORDER BY price_per_m2)   AS m2_hi,
           -- "recent months are incomplete": 10% of sales are first published
           -- medians keep moving as late registrations arrive
           max(contract_date) - interval '7 months'                      AS incomplete_from
      FROM priced
     WHERE is_standard_sale
),
-- scored: priced with three Flag-conditions (price-outlier,
-- missing contract date, to young Period).
scored AS (
    SELECT p.*,
           (p.purchase_price IS NOT NULL
             AND (p.purchase_price < greatest(b.p_lo, 1000) OR p.purchase_price > b.p_hi))
            OR (p.price_per_m2 IS NOT NULL
             AND (p.price_per_m2 < b.m2_lo OR p.price_per_m2 > b.m2_hi)) AS price_outlier,
           (p.contract_date IS NULL)                                     AS no_contract_date,
           (p.contract_date IS NOT NULL AND p.contract_date > b.incomplete_from)
                                                                         AS period_incomplete
      FROM priced p CROSS JOIN bounds b
)
SELECT s.dealing_number,
       s.parcel_seq,
       s.property_id,
       s.district_code,
       nullif(trim(s.district_name), ''),
       s.contract_date,
       s.settlement_date,
       extract(year FROM s.contract_date)::smallint,
       CASE WHEN s.contract_date IS NOT NULL
            THEN to_char(s.contract_date, 'YYYY"Q"Q') END,
       s.purchase_price,
       s.area_norm_m2,
       upper(nullif(trim(s.area_type), '')),
       s.price_per_m2,
       s.property_type,
       s.nature_of_property,
       nullif(trim(s.zoning), ''),
       s.strata_lot_number,
       nullif(trim(s.address_label), ''),
       upper(nullif(trim(s.locality), '')),
       CASE WHEN trim(s.postcode) ~ '^[0-9]{4}$' THEN trim(s.postcode) END,
       nullif(trim(s.lotidstring), ''),
       -- NULL street name or locality means there is no street key at all
       -- drops the NULL, producing a hash that matches no street_locality row.
       CASE WHEN nullif(trim(s.street_name_core), '') IS NOT NULL
                 AND nullif(trim(s.locality), '') IS NOT NULL
            THEN md5(concat_ws('||', upper(trim(s.street_name_core)),
                     coalesce(silver.street_type_key(s.street_type_code), ''),
                     coalesce(upper(nullif(trim(s.street_suffix_code), '')), ''),
                     upper(trim(s.locality)),
                     coalesce(CASE WHEN trim(s.postcode) ~ '^[0-9]{4}$'
                                   THEN trim(s.postcode) END, ''))) END,
       'none',                                       -- geocode_level: no coords exist
       coalesce(s.is_standard_sale, false),
       coalesce(s.price_outlier, false),
       s.no_contract_date,
       coalesce(s.period_incomplete, false),
       (coalesce(s.flag_bad_date, false) OR coalesce(s.settlement_date < s.contract_date, false)),
       coalesce(s.is_standard_sale, false)
         AND NOT s.no_contract_date
         AND NOT (coalesce(s.flag_bad_date, false) OR coalesce(s.settlement_date < s.contract_date, false))
         AND coalesce(s.purchase_price >= 1000, false)
  FROM scored s
ON CONFLICT (dealing_number, parcel_seq) DO UPDATE
   SET purchase_price         = EXCLUDED.purchase_price,
       area_m2                = EXCLUDED.area_m2,
       price_per_m2           = EXCLUDED.price_per_m2,
       contract_date          = EXCLUDED.contract_date,
       settlement_date        = EXCLUDED.settlement_date,
       property_type          = EXCLUDED.property_type,
       street_id              = EXCLUDED.street_id,
       flag_price_outlier     = EXCLUDED.flag_price_outlier,
       flag_period_incomplete = EXCLUDED.flag_period_incomplete,
       is_usable              = EXCLUDED.is_usable,
       loaded_at              = now()
 WHERE (t.purchase_price, t.area_m2, t.property_type, t.street_id, t.is_usable)
       IS DISTINCT FROM
       (EXCLUDED.purchase_price, EXCLUDED.area_m2, EXCLUDED.property_type,
        EXCLUDED.street_id, EXCLUDED.is_usable);


-- Place the sale at its street's centre (see 40_street_locality.sql: derived
-- from the DA points). This is a STREET geocode, not an address one, which is
-- why geocode_level and flag_coarse_geocode exist - don't mistake it for a parcel.
UPDATE silver.property_sale s
   SET geom                = l.centroid,
       geom_m              = l.centroid_m,
       hex_id              = l.hex_id,
       geocode_level       = 'street',
       flag_coarse_geocode = l.flag_coarse_geocode
  FROM silver.street_locality l
 WHERE l.street_id = s.street_id
   AND l.centroid IS NOT NULL
;
