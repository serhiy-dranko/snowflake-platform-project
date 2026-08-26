--1. Load raw_order_items.json

CREATE OR REPLACE TABLE raw_order_items_variant (data VARIANT);

COPY INTO raw_order_items_variant
FROM @json_stage/raw_order_items.json
FILE_FORMAT = (FORMAT_NAME = json_ff);

-- Status LOADED 
-- rows_parsed 3000
-- rows_loaded 3000

--2. Flatten both nesting levels

-- one level: items
USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw;  

SELECT
  data:order_id::INT           AS order_id,
  item.value:item_id::INT      AS item_id,
  item.value:product::STRING   AS product,
  item.value:price::FLOAT      AS item_price
FROM snowflake_platform_project.raw.raw_order_items_variant,
     LATERAL FLATTEN(input => data:items) AS item;

-- Rows loaded 7544

-- two levels: items, then modifiers within each item
USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw;  

SELECT
  data:order_id::INT                       AS order_id,
  item.value:item_id::INT                  AS item_id,
  item.value:product::STRING               AS product,
  modifier.value:name::STRING              AS modifier_name,
  modifier.value:price::FLOAT              AS modifier_price
FROM raw_order_items_variant,
     LATERAL FLATTEN(input => data:items) AS item,
     LATERAL FLATTEN(input => item.value:modifiers, OUTER => TRUE) AS modifier;

-- Rows loaded 9779

--3. Views vs. materialized view

USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw;  


CREATE VIEW snowflake_platform_project.raw.vw_order_item_totals AS
SELECT
  data:order_id::INT AS order_id,
  SUM(item.value:price::FLOAT) AS items_subtotal
FROM snowflake_platform_project.raw.raw_order_items_variant,
     LATERAL FLATTEN(input => data:items) AS item
GROUP BY data:order_id::INT;

-- Status View MV_ORDER_ITEM_TOTALS successfully created.

CREATE MATERIALIZED VIEW snowflake_platform_project.raw.mv_order_item_totals AS
SELECT
  data:order_id::INT AS order_id,
  SUM(item.value:price::FLOAT) AS items_subtotal
FROM snowflake_platform_project.raw.raw_order_items_variant,
     LATERAL FLATTEN(input => data:items) AS item
GROUP BY data:order_id::INT;

-- Status Materialized view MV_ORDER_ITEM_TOTALS successfully created.

--4. Time Travel — recover from a bad UPDATE

USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw;  

-- note the current time first
SELECT CURRENT_TIMESTAMP();

-- '2026-08-25 12:13:56:512 -0700'

-- deliberately break some data
UPDATE raw_orders SET order_total = 0 WHERE UNIFORM(0,1,RANDOM()) < 0.1;

-- number of rows updated : 500278

-- confirm the damage
SELECT COUNT(*) FROM raw_orders WHERE order_total = 0;

-- COUNT(*) : 500278

-- recover using Time Travel, comparing against the pre-update state
SELECT COUNT(*) FROM raw_orders AT (OFFSET => -60*5) WHERE order_total = 0;

-- COUNT(*) : 0

-- restore (pick one approach and justify it):
CREATE OR REPLACE TABLE raw_orders AS
SELECT * FROM raw_orders BEFORE (STATEMENT => '01c6a03e-0108-0668-0005-4c7a001c2a16');

-- Status: Table RAW_ORDERS successfully created.

SELECT COUNT(*) FROM raw_orders WHERE order_total = 0;

-- COUNT(*) : 0

--5. Zero-copy clone

USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;
USE SCHEMA snowflake_platform_project.raw; 

CREATE TABLE dev_orders CLONE raw_orders;

-- Status: Table DEV_ORDERS successfuly created.

-- confirm it's a full logical copy
SELECT COUNT(*) FROM dev_orders;

-- COUNT(*) : 1 000 497

UPDATE dev_orders SET status = 'returned' WHERE order_id = 1;

-- number_of_rows_updated : 1

-- confirm the original is untouched
SELECT status FROM raw_orders WHERE order_id = 1;

-- Status: delivered

SELECT status FROM dev_orders WHERE order_id = 1;

-- Status: returned

--6. Check Time Travel retention window

USE ROLE data_engineer;
USE WAREHOUSE project_wh;
USE DATABASE snowflake_platform_project;


SELECT RETENTION_TIME
FROM snowflake_platform_project.INFORMATION_SCHEMA.TABLES
WHERE TABLE_SCHEMA = 'RAW' AND TABLE_NAME = 'RAW_ORDERS';

-- RETENTION_TIME : 1

-- Notice that 'DATA_RETENTION_TIME_IN_DAYS' dosen't exist in table schema.

