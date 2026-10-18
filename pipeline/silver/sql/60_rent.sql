-- Rent remains LGA/period/dwelling grain. Missing values are not imputed.
-- Only creates table: one row per rent observation
CREATE TABLE IF NOT EXISTS silver.rent_observation (
    rent_id            integer      PRIMARY KEY,
    lga_name           text,
    lga_key            text         NOT NULL,
    period_start       date,
    dwelling_type      text,
    bedrooms           text,
    median_weekly_rent numeric(10,2),
    new_bonds_count    integer,
    reliability_flag   text,
    flag_missing_rent  boolean      NOT NULL,
    flag_invalid_value boolean      NOT NULL,
    is_usable          boolean      NOT NULL,
    raw_record_id      bigint,
    record_source      text         NOT NULL DEFAULT 'NSW_RENT_BONDS',
    loaded_at          timestamptz  NOT NULL DEFAULT now()
);

-- bedrooms: is not in the original rent data
ALTER TABLE bronze.rent_data ADD COLUMN IF NOT EXISTS bedrooms text;

-- get data from bronze: lga_key normalisation and quality flags calculations
INSERT INTO silver.rent_observation
    (rent_id, lga_name, lga_key, period_start, dwelling_type, bedrooms,
     median_weekly_rent, new_bonds_count, reliability_flag,
     flag_missing_rent, flag_invalid_value, is_usable, raw_record_id)
SELECT rent_id,
       nullif(trim(lga_name), ''),
       silver.lga_key(lga_name),
       period_start,
       lower(nullif(trim(dwelling_type), '')),
       nullif(trim(bedrooms), ''),
       median_weekly_rent,
       new_bonds_count,
       reliability_flag,
       median_weekly_rent IS NULL,                                     -- flag_missing_rent
       coalesce(median_weekly_rent <= 0, false)
         OR coalesce(new_bonds_count < 0, false),                      -- flag_invalid_value
       coalesce(median_weekly_rent > 0, false)
         AND period_start IS NOT NULL
         AND nullif(trim(lga_name), '') IS NOT NULL
         AND coalesce(new_bonds_count >= 0, false)
         AND lower(coalesce(reliability_flag, '')) IN ('n', 'normal', 'reliable', 'reported'),  -- is_usable
       _raw_record_id
  FROM bronze.rent_data;

-- per stop and period of rent context: connect all the lgas of every bus-stops with every rent_observation row
-- Period and dwelling stay in ther one granuality, instead of the newest quartal to collapse. 
CREATE TABLE IF NOT EXISTS silver.bus_stop_rent (
    stop_id               integer NOT NULL REFERENCES silver.bus_stop,
    rent_id               integer NOT NULL REFERENCES silver.rent_observation,
    lga_assignment_method text    NOT NULL,
    PRIMARY KEY (stop_id, rent_id)
);

-- every Stop with every useful rent-row connect with his LGA, not that complicated
INSERT INTO silver.bus_stop_rent
SELECT m.stop_id, r.rent_id, m.assignment_method
  FROM silver.bus_stop_lga m
  JOIN silver.rent_observation r ON r.lga_key = m.lga_code
 WHERE r.is_usable;
