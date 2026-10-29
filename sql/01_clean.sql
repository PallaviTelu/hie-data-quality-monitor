-- 01_clean.sql
-- Standardize and validate the raw extracts.
-- Input tables (loaded by scripts/run_pipeline.py, all TEXT columns):
--   raw_facilities, raw_submissions, raw_errors
-- Output tables:
--   facilities, clean_submissions, rejected_submissions,
--   clean_errors, rejected_errors

-- ---------------------------------------------------------------------------
-- Facility master
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS facilities;
CREATE TABLE facilities AS
SELECT
    facility_id,
    facility_name,
    facility_type,
    county,
    onboarding_date
FROM raw_facilities;

-- ---------------------------------------------------------------------------
-- Staging: submissions with standardized ID, month, and date
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_submissions;
CREATE TABLE stg_submissions AS
SELECT
    rowid AS raw_row_id,
    facility_id AS raw_facility_id,
    submission_month AS raw_month,
    last_received_date AS raw_received_date,

    -- "fac-007", "FAC007", " FAC-007 ", "Fac 007" -> "FAC-007"
    'FAC-' || substr(upper(replace(replace(trim(facility_id), '-', ''), ' ', '')), 4) AS facility_id,

    -- "2026-01" | "01/2026" | "Jan 2026" -> "2026-01"
    CASE
        WHEN submission_month GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'
            THEN submission_month
        WHEN submission_month GLOB '[0-9][0-9]/[0-9][0-9][0-9][0-9]'
            THEN substr(submission_month, 4, 4) || '-' || substr(submission_month, 1, 2)
        WHEN submission_month GLOB '[A-Z][a-z][a-z] [0-9][0-9][0-9][0-9]'
            THEN substr(submission_month, 5, 4) || '-' ||
                 CASE substr(submission_month, 1, 3)
                     WHEN 'Jan' THEN '01' WHEN 'Feb' THEN '02' WHEN 'Mar' THEN '03'
                     WHEN 'Apr' THEN '04' WHEN 'May' THEN '05' WHEN 'Jun' THEN '06'
                     WHEN 'Jul' THEN '07' WHEN 'Aug' THEN '08' WHEN 'Sep' THEN '09'
                     WHEN 'Oct' THEN '10' WHEN 'Nov' THEN '11' WHEN 'Dec' THEN '12'
                 END
    END AS report_month,

    -- "2026-01-23" | "01/23/2026" -> "2026-01-23"
    CASE
        WHEN last_received_date GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'
            THEN last_received_date
        WHEN last_received_date GLOB '[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]'
            THEN substr(last_received_date, 7, 4) || '-' ||
                 substr(last_received_date, 1, 2) || '-' ||
                 substr(last_received_date, 4, 2)
    END AS last_received_date,

    CAST(NULLIF(trim(record_count), '') AS INTEGER) AS record_count
FROM raw_submissions;

-- ---------------------------------------------------------------------------
-- Classify each staged submission row; rank duplicates
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_submissions_flagged;
CREATE TABLE stg_submissions_flagged AS
WITH cfg AS (
    SELECT
        (SELECT value FROM config WHERE key = 'max_record_count') AS max_rc,
        (SELECT value FROM config WHERE key = 'min_record_count') AS min_rc
),
checked AS (
    SELECT
        s.*,
        CASE
            WHEN s.report_month IS NULL THEN 'Unparseable month'
            WHEN s.facility_id NOT IN (SELECT facility_id FROM facilities) THEN 'Unknown facility ID'
            WHEN s.record_count IS NULL THEN 'Missing record count'
            WHEN s.record_count < (SELECT min_rc FROM cfg)
              OR s.record_count > (SELECT max_rc FROM cfg) THEN 'Out-of-range record count'
        END AS reject_reason
    FROM stg_submissions s
),
ranked AS (
    SELECT
        c.*,
        -- among otherwise-valid rows, keep one per facility-month:
        -- latest received date first, then the larger record count
        CASE WHEN c.reject_reason IS NULL THEN
            ROW_NUMBER() OVER (
                PARTITION BY c.facility_id, c.report_month
                ORDER BY c.last_received_date DESC, c.record_count DESC, c.raw_row_id
            )
        END AS dup_rank
    FROM checked c
)
SELECT
    *,
    CASE
        WHEN reject_reason IS NOT NULL THEN reject_reason
        WHEN dup_rank > 1 THEN 'Duplicate facility-month'
    END AS final_reject_reason
FROM ranked;

DROP TABLE IF EXISTS clean_submissions;
CREATE TABLE clean_submissions AS
SELECT facility_id, report_month, record_count, last_received_date
FROM stg_submissions_flagged
WHERE final_reject_reason IS NULL;

DROP TABLE IF EXISTS rejected_submissions;
CREATE TABLE rejected_submissions AS
SELECT
    'monthly_submissions' AS source_table,
    raw_row_id,
    raw_facility_id AS raw_facility_id,
    raw_month AS raw_month,
    record_count AS value,
    final_reject_reason AS reject_reason
FROM stg_submissions_flagged
WHERE final_reject_reason IS NOT NULL;

-- ---------------------------------------------------------------------------
-- Validation errors: standardize and validate
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS stg_errors;
CREATE TABLE stg_errors AS
SELECT
    rowid AS raw_row_id,
    facility_id AS raw_facility_id,
    report_month AS raw_month,
    'FAC-' || substr(upper(replace(replace(trim(facility_id), '-', ''), ' ', '')), 4) AS facility_id,
    CASE
        WHEN report_month GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'
            THEN report_month
        WHEN report_month GLOB '[0-9][0-9]/[0-9][0-9][0-9][0-9]'
            THEN substr(report_month, 4, 4) || '-' || substr(report_month, 1, 2)
        WHEN report_month GLOB '[A-Z][a-z][a-z] [0-9][0-9][0-9][0-9]'
            THEN substr(report_month, 5, 4) || '-' ||
                 CASE substr(report_month, 1, 3)
                     WHEN 'Jan' THEN '01' WHEN 'Feb' THEN '02' WHEN 'Mar' THEN '03'
                     WHEN 'Apr' THEN '04' WHEN 'May' THEN '05' WHEN 'Jun' THEN '06'
                     WHEN 'Jul' THEN '07' WHEN 'Aug' THEN '08' WHEN 'Sep' THEN '09'
                     WHEN 'Oct' THEN '10' WHEN 'Nov' THEN '11' WHEN 'Dec' THEN '12'
                 END
    END AS report_month,
    trim(error_type) AS error_type,
    CAST(NULLIF(trim(error_count), '') AS INTEGER) AS error_count
FROM raw_errors;

DROP TABLE IF EXISTS stg_errors_flagged;
CREATE TABLE stg_errors_flagged AS
SELECT
    e.*,
    CASE
        WHEN e.report_month IS NULL THEN 'Unparseable month'
        WHEN e.facility_id NOT IN (SELECT facility_id FROM facilities) THEN 'Unknown facility ID'
        WHEN e.error_count IS NULL OR e.error_count < 0 THEN 'Invalid error count'
    END AS reject_reason
FROM stg_errors e;

DROP TABLE IF EXISTS clean_errors;
CREATE TABLE clean_errors AS
SELECT facility_id, report_month, error_type, SUM(error_count) AS error_count
FROM stg_errors_flagged
WHERE reject_reason IS NULL
GROUP BY facility_id, report_month, error_type;

DROP TABLE IF EXISTS rejected_errors;
CREATE TABLE rejected_errors AS
SELECT
    'validation_errors' AS source_table,
    raw_row_id,
    raw_facility_id,
    raw_month,
    error_count AS value,
    reject_reason
FROM stg_errors_flagged
WHERE reject_reason IS NOT NULL;
