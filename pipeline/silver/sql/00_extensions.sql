-- Source https://docs.postgrest.org/en/v16/integrations/postgis.html#
-- https://postgis.net/docs/reference.html
CREATE EXTENSION IF NOT EXISTS postgis; -- Very important now we can work with GeoData
CREATE SCHEMA IF NOT EXISTS silver;
-- This Function takes JSON Data and tries to bring it into POSTGis Geometry
CREATE OR REPLACE FUNCTION silver.safe_geometry(j jsonb) RETURNS geometry
LANGUAGE plpgsql IMMUTABLE AS $$
DECLARE g geometry;
BEGIN
 IF j IS NULL THEN RETURN NULL; END IF;
 g := ST_SetSRID(ST_GeomFromGeoJSON(j),4326);
 IF ST_IsEmpty(g) OR NOT ST_IsValid(g) THEN RETURN NULL; END IF;
 IF ST_XMin(Box3D(g)) < -180 OR ST_XMax(Box3D(g)) > 180 -- Check if it is in the world longitude
 OR ST_YMin(Box3D(g)) < -90 OR ST_YMax(Box3D(g)) > 90 THEN RETURN NULL; END IF; -- latidude
 RETURN g;
EXCEPTION WHEN OTHERS THEN RETURN NULL;
END $$;

-- Just Abbrevations to make live easier in the database
-- Because different abbrevation used in sources
CREATE OR REPLACE FUNCTION silver.street_type_key(v text) RETURNS text
LANGUAGE sql IMMUTABLE AS $$
 SELECT CASE upper(trim(v)) WHEN 'STREET' THEN 'ST' WHEN 'ROAD' THEN 'RD'
 WHEN 'AVENUE' THEN 'AVE' WHEN 'PARADE' THEN 'PDE' WHEN 'CRESCENT' THEN 'CRES'
 WHEN 'DRIVE' THEN 'DR' WHEN 'HIGHWAY' THEN 'HWY' WHEN 'PLACE' THEN 'PL'
 WHEN 'COURT' THEN 'CT' WHEN 'LANE' THEN 'LN' WHEN 'TERRACE' THEN 'TCE'
 WHEN 'CLOSE' THEN 'CL' WHEN 'BOULEVARD' THEN 'BVD'
 ELSE nullif(upper(trim(v)),'') END;
$$;
