-- gold.fact_address / dim_locality / dim_street - the dimensional mart for the
-- address report (counts and rollups by locality, LGA, street, precision
-- tier, accuracy), as distinct from gold.address_point (the type-ahead /
-- resolve index the website's geocoder hits directly, and which this file
-- never touches). One row per gold.address_point row; built after it, so it
-- only ever reads an already-populated table.
--
-- No dim_precision: the column has exactly two values ('address'/'street'),
-- already CHECK-constrained on address_point, and never grows - a lookup
-- table would be a join for no information.
--
-- locality_id reuses gold.suburb_comparison's locality key for the LGA
-- lookup rather than inventing a second locality identifier scheme; a
-- locality absent from suburb_comparison (filtered out there by its own
-- minimum-sales threshold) simply carries a NULL lga_code/lga_name here.
--
-- dim_locality's rows come from address_point AND street_locality, not just
-- address_point: street_locality carries every street, including the ones
-- 30_address_point.sql's street tier filters out (no centroid, no label),
-- and dim_street is a complete street dimension, not one trimmed to match
-- fact_address - so its locality_id must resolve regardless of whether that
-- street made it into address_point's street tier.

CREATE TABLE IF NOT EXISTS gold.dim_locality (
    locality_id   text        PRIMARY KEY,   -- locality || '|' || coalesce(postcode,'')
    locality      text        NOT NULL,
    postcode      text,
    lga_code      text,
    lga_name      text,
    loaded_at     timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS dim_locality_lga_idx ON gold.dim_locality (lga_code);

CREATE TABLE IF NOT EXISTS gold.dim_street (
    street_id           text        PRIMARY KEY,
    street_name_core    text,
    street_type_code    text,
    street_suffix_code  text,
    street_label        text,
    locality_id         text        REFERENCES gold.dim_locality,
    loaded_at           timestamptz NOT NULL DEFAULT now()
);

-- ON DELETE CASCADE: 30_address_point.sql clears address_point before this
-- step runs, and the fact rows built from it go with it.
CREATE TABLE IF NOT EXISTS gold.fact_address (
    address_id       text          PRIMARY KEY REFERENCES gold.address_point ON DELETE CASCADE,
    address_text     text          NOT NULL,
    locality_id      text          REFERENCES gold.dim_locality,
    street_id        text          REFERENCES gold.dim_street,   -- NULL for the 'address' tier
    precision        text          NOT NULL CHECK (precision IN ('address', 'street')),
    accuracy_m       numeric(10,2) NOT NULL,
    accuracy_bucket  text          NOT NULL,   -- 'exact' | '<=100m' | '100-300m' | '>300m'
    hex_id           text,
    loaded_at        timestamptz   NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS fact_address_locality_idx  ON gold.fact_address (locality_id);
CREATE INDEX IF NOT EXISTS fact_address_precision_idx ON gold.fact_address (precision);

-- Clear children before parents, or a re-run hits its own foreign keys.
DELETE FROM gold.fact_address;
DELETE FROM gold.dim_street;
DELETE FROM gold.dim_locality;

INSERT INTO gold.dim_locality (locality_id, locality, postcode, lga_code, lga_name)
SELECT loc.locality || '|' || coalesce(loc.postcode, ''), loc.locality, loc.postcode,
       sc.lga_code, sc.lga_name
  FROM (
           SELECT locality, postcode FROM gold.address_point WHERE locality IS NOT NULL
           UNION
           SELECT locality, postcode FROM silver.street_locality WHERE locality IS NOT NULL
       ) loc
  LEFT JOIN gold.suburb_comparison sc ON sc.locality = loc.locality;

INSERT INTO gold.dim_street (street_id, street_name_core, street_type_code, street_suffix_code,
                              street_label, locality_id)
SELECT l.street_id, l.street_name_core, l.street_type_code, l.street_suffix_code,
       l.street_label, l.locality || '|' || coalesce(l.postcode, '')
  FROM silver.street_locality l;

INSERT INTO gold.fact_address (address_id, address_text, locality_id, street_id, precision,
                                accuracy_m, accuracy_bucket, hex_id)
SELECT a.address_id, a.address_text,
       a.locality || '|' || coalesce(a.postcode, ''),
       a.street_id, a.precision, a.accuracy_m,
       CASE WHEN a.accuracy_m = 0 THEN 'exact'
            WHEN a.accuracy_m <= 100 THEN '<=100m'
            WHEN a.accuracy_m <= 300 THEN '100-300m'
            ELSE '>300m' END,
       a.hex_id
  FROM gold.address_point a;
