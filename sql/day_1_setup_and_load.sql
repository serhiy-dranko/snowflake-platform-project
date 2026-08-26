-- 1. Database, schema, warehouse

-- as ACCOUNTADMIN
CREATE DATABASE IF NOT EXISTS snowflake_platform_project;
CREATE SCHEMA IF NOT EXISTS snowflake_platform_project.raw;

CREATE WAREHOUSE IF NOT EXISTS project_wh
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

-- Status Schema RAW successfully created.

-- 2. Role hierarchy and future grants

-- as ACCOUNTADMIN
CREATE ROLE IF NOT EXISTS data_engineer;
CREATE ROLE IF NOT EXISTS analyst_readonly;

GRANT ROLE data_engineer TO ROLE sysadmin;
GRANT ROLE analyst_readonly TO ROLE sysadmin;
GRANT ROLE data_engineer TO USER DRANKOSERHIY;
GRANT ROLE analyst_readonly TO USER DRANKOSERHIY;

GRANT USAGE ON DATABASE snowflake_platform_project TO ROLE data_engineer;
GRANT USAGE ON DATABASE snowflake_platform_project TO ROLE analyst_readonly;
GRANT USAGE ON SCHEMA snowflake_platform_project.raw TO ROLE data_engineer;
GRANT USAGE ON SCHEMA snowflake_platform_project.raw TO ROLE analyst_readonly;
GRANT USAGE ON WAREHOUSE project_wh TO ROLE data_engineer;
GRANT USAGE ON WAREHOUSE project_wh TO ROLE analyst_readonly;

GRANT CREATE TABLE, CREATE STAGE, CREATE FILE FORMAT
  ON SCHEMA snowflake_platform_project.raw TO ROLE data_engineer;

-- future grants: anything created in raw from now on is auto-readable by analyst_readonly
GRANT SELECT ON FUTURE TABLES IN SCHEMA snowflake_platform_project.raw
  TO ROLE analyst_readonly;

-- Status Statement executed successfully.

-- 3.File format and internal stage

USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE SNOWFLAKE_PLATFORM_PROJECT;
USE SCHEMA RAW;

CREATE FILE FORMAT csv_ff
  TYPE = 'CSV'
  FIELD_DELIMITER = ','
  SKIP_HEADER = 1
  NULL_IF = ('', 'NULL')
  EMPTY_FIELD_AS_NULL = TRUE;

  CREATE STAGE raw_stage
  FILE_FORMAT = csv_ff;

-- Status Stage area RAW_STAGE successfully created.

-- 4.Generate raw_customers (~50K rows) and raw_orders (1M+ rows)

CREATE OR REPLACE TABLE raw_customers AS
SELECT
  SEQ8() + 1                                       AS customer_id,
  'customer_' || (SEQ8() + 1)                      AS customer_name,
  ARRAY_CONSTRUCT('DE','FR','ES','IT','NL')[UNIFORM(0,4,RANDOM())] AS country
FROM TABLE(GENERATOR(ROWCOUNT => 50000));

-- Status Table RAW_CUSTOMERS successfully created.

CREATE OR REPLACE TABLE raw_orders AS
SELECT
  SEQ8() + 1                                            AS order_id,
  UNIFORM(1, 50000, RANDOM())                           AS customer_id,
  DATEADD(day, -UNIFORM(0, 730, RANDOM()), CURRENT_DATE()) AS order_date,
  ROUND(UNIFORM(5, 50000, RANDOM()) / 100.0, 2)         AS order_total,
  ARRAY_CONSTRUCT('placed','shipped','delivered','returned')[UNIFORM(0,3,RANDOM())] AS status
FROM TABLE(GENERATOR(ROWCOUNT => 1000000));

-- Status Table RAW_ORDERS successfully created.

-- 5.Load a CSV through the stage properly (with a deliberately bad row)

COPY INTO raw_orders
FROM @raw_stage/late_orders.csv
FILE_FORMAT = (FORMAT_NAME = csv_ff)
VALIDATION_MODE = 'RETURN_ERRORS';

-- Errors:
 
-- Field delimiter ',' found while expecting record delimiter '\n' Line 10 Character 41
-- Numeric value 'jhon do' is not recognized Line 13 Character 9
-- Numeric value 'Not_a_number' is not recognized Line 12 Character 26

COPY INTO raw_orders
FROM @raw_stage/late_orders.csv
FILE_FORMAT = (FORMAT_NAME = csv_ff)
ON_ERROR = 'CONTINUE';

-- Status PARTIALLY_LOADED
-- rows parsed  500
-- rows lodaded 497
-- errors seen 3

SELECT *
FROM TABLE(INFORMATION_SCHEMA.COPY_HISTORY(
  TABLE_NAME => 'RAW_ORDERS',
  START_TIME => DATEADD(hour, -1, CURRENT_TIMESTAMP())
));

-- LAST LOAD TIME 2026-08-24 23:31:44.164 -0700

-- 6.Verify grants independently with SHOW GRANTS

SHOW GRANTS TO ROLE data_engineer;
SHOW GRANTS TO ROLE analyst_readonly;
SHOW GRANTS ON TABLE raw_orders;

-- ANALYST_READONLY privilege SELECT grant_option false
-- DATA_ENGINEER privilege OWNERSHIP grant_option true




