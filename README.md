# Snowflake Platform Project

A week-long, hands-on Snowflake learning project at 14th Week in Dataskool.

## Project structure

```
snowflake-platform-project/
├── README.md
├── sql/
│   ├── day1_setup_and_load.sql
│   └── day2_variant_and_time_travel.sql
└── data/
│   ├── late_orders.csv                    (sample file with deliberate bad rows)
│   └── raw_order_items.json               (nested JSON: orders → items → modifiers)
└── screenshots/
    ├── day_1/
    │   ├── analyst_readonly_failing.png   (proof that analyst role has permission only for Select)
    │   ├── raw_customers.png              (count of rows in table)
    │   └── raw_orders.png                 (count of rows in table)
    └── day_2/

```

## Environment

- Database: `SNOWFLAKE_PLATFORM_PROJECT`
- Schema: `RAW`
- Warehouse: `PROJECT_WH` (X-Small, auto-suspend 60s)
- Roles: `SYSADMIN` → `DATA_ENGINEER` (load/transform), `ANALYST_READONLY` (SELECT only, via
  future grants)

---

## Day 1 — Account Setup, Role Hierarchy, Warehouses, Loading at Scale

**Built:**
- Database, `RAW` schema, X-Small warehouse
- Role hierarchy under `SYSADMIN`, with `GRANT SELECT ON FUTURE TABLES` for `ANALYST_READONLY`
- `raw_customers` (~50K rows) and `raw_orders` (1M+ rows), generated via `GENERATOR` / `SEQ8` /
  `UNIFORM`
- Real file load path: CSV with 3 deliberately malformed rows → `PUT` → `VALIDATION_MODE` →
  `COPY INTO ... ON_ERROR='CONTINUE'` → verified via `COPY_HISTORY`
- Grants independently verified with `SHOW GRANTS` (not just the role-switch test)

**Real issues hit and fixed (not in the original plan — genuine debugging practice):**
- `ARRAY_CONSTRUCT(...)[UNIFORM(...)]` returns `VARIANT`, not `VARCHAR` — CSV-exported values came
  out double-quoted (`"""placed"""`). Fixed by casting to `::STRING` in the `SELECT`, which requires
  `CREATE OR REPLACE TABLE ... AS SELECT` (an `UPDATE` can't change a column's underlying type).
- Wrong staged file name (`.csv` vs assumed `.csv.gz`) silently returned zero rows instead of an
  error — always confirm the exact name with `LIST @stage;` first.
- `VARIANT` status column caused `COPY INTO` to try (and fail) parsing every plain-text value as
  JSON, masking the real malformed-row errors underneath a wall of `Error parsing JSON` noise.

**Result:** 497 of 500 late-arriving rows loaded; 3 deliberately bad rows rejected and confirmed via
`COPY_HISTORY`; grants confirmed to survive re-verification.

---

## Day 2 — Semi-Structured Data, Views, Time Travel, Cloning

**Built:**
- `raw_order_items.json` (3,000 orders, 7,544 items, 7,492 modifiers, 2,287 items with zero
  modifiers) loaded into a `VARIANT` column
- Two-level `FLATTEN` + `LATERAL` (items, then modifiers), row counts sanity-checked at each level:
  - Items only: 7,544 rows
  - Modifiers, no `OUTER => TRUE`: 7,492 rows (items with empty modifier arrays silently dropped)
  - Modifiers, with `OUTER => TRUE`: 9,779 rows = 7,492 + 2,287 (empty-modifier items kept, `NULL`)
- `vw_order_item_totals` (view) and `mv_order_item_totals` (materialized view) — both return 3,000
  rows. **Decision:** a plain view is the right call here — the underlying query is cheap (small
  table, one `FLATTEN` + `SUM`) and the base data is static, so a materialized view's storage and
  background-maintenance cost wouldn't be justified.
- Deliberate bad `UPDATE` on `raw_orders`, recovered via Time Travel `BEFORE (STATEMENT => query_id)`
  rather than `UNDROP`
- Zero-copy clone `dev_orders`, modified independently, confirmed `raw_orders` untouched
- `DATA_RETENTION_TIME_IN_DAYS` = 1 (account default) — a mistake caught more than a day late
  would need Fail-safe (Enterprise+, Snowflake Support only) or an external backup instead.

**Real issues hit and fixed:**
- `UNIFORM(0, 1, RANDOM())` with integer bounds returns an *integer* (0 or 1, 50/50), not a float —
  so `WHERE UNIFORM(0,1,RANDOM()) < 0.1` corrupted ~50% of rows instead of the intended ~10%. Fix:
  use float bounds (`UNIFORM(0::FLOAT, 1::FLOAT, RANDOM())`) or an integer range check instead
  (`UNIFORM(1,10,RANDOM()) = 1`).
- `INFORMATION_SCHEMA.TABLES` does not have a `DATA_RETENTION_TIME_IN_DAYS` column — that name only
  applies to the object parameter (`SHOW PARAMETERS ... IN TABLE ...`). The equivalent
  `INFORMATION_SCHEMA` column is `RETENTION_TIME`.
- Session repeatedly lost its database/schema context ("This session does not have a current
  database") — worked around by fully qualifying every object
  (`snowflake_platform_project.raw.<object>`) rather than relying on `USE DATABASE` / `USE SCHEMA`
  persisting.

**Result:** both flatten levels verified by row count, Time Travel recovery brought corrupted-row
count from 500,278 back to 0, clone divergence test passed, retention window documented.

---
