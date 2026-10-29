-- 04_validation_checks.sql
-- Data-quality scorecard for the latest run. Feeds the dashboard's data-quality panel.
-- Output table: validation_summary
--
-- Columns:
--   check_id      stable ID used in the SOP
--   check_name    what was tested
--   rows_checked  denominator
--   issues_found  number of rows (or facilities) failing the check
--   pct_issues    issues_found / rows_checked
--   handling      what the pipeline does with failing rows

DROP TABLE IF EXISTS validation_summary;
CREATE TABLE validation_summary AS
WITH
sub_total AS (SELECT COUNT(*) AS n FROM stg_submissions),
err_total AS (SELECT COUNT(*) AS n FROM stg_errors),
fm_total  AS (SELECT COUNT(*) AS n FROM facility_month_status),
fac_total AS (SELECT COUNT(*) AS n FROM facilities)
SELECT * FROM (
    SELECT 'V01' AS check_id,
           'Facility ID not in standard FAC-### format (submissions)' AS check_name,
           (SELECT n FROM sub_total) AS rows_checked,
           (SELECT COUNT(*) FROM stg_submissions
             WHERE raw_facility_id NOT GLOB 'FAC-[0-9][0-9][0-9]') AS issues_found,
           'Standardized to FAC-###' AS handling
    UNION ALL
    SELECT 'V02', 'Month not in YYYY-MM format (submissions)',
           (SELECT n FROM sub_total),
           (SELECT COUNT(*) FROM stg_submissions
             WHERE raw_month NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]'),
           'Standardized to YYYY-MM'
    UNION ALL
    SELECT 'V03', 'Received date not in YYYY-MM-DD format (submissions)',
           (SELECT COUNT(*) FROM stg_submissions WHERE trim(raw_received_date) <> ''),
           (SELECT COUNT(*) FROM stg_submissions
             WHERE trim(raw_received_date) <> ''
               AND raw_received_date NOT GLOB '[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]'),
           'Standardized to YYYY-MM-DD'
    UNION ALL
    SELECT 'V04', 'Missing record count',
           (SELECT n FROM sub_total),
           (SELECT COUNT(*) FROM stg_submissions_flagged WHERE final_reject_reason = 'Missing record count'),
           'Row quarantined; facility-month flagged Data Incomplete'
    UNION ALL
    SELECT 'V05', 'Record count out of range (negative or above max)',
           (SELECT n FROM sub_total),
           (SELECT COUNT(*) FROM stg_submissions_flagged WHERE final_reject_reason = 'Out-of-range record count'),
           'Row quarantined; facility-month flagged Data Incomplete'
    UNION ALL
    SELECT 'V06', 'Duplicate facility-month rows',
           (SELECT n FROM sub_total),
           (SELECT COUNT(*) FROM stg_submissions_flagged WHERE final_reject_reason = 'Duplicate facility-month'),
           'Kept latest received date, then larger count; others quarantined'
    UNION ALL
    SELECT 'V07', 'Unknown facility ID (submissions)',
           (SELECT n FROM sub_total),
           (SELECT COUNT(*) FROM stg_submissions_flagged WHERE final_reject_reason = 'Unknown facility ID'),
           'Row quarantined; follow up with feed owner'
    UNION ALL
    SELECT 'V08', 'Unknown facility ID (validation errors)',
           (SELECT n FROM err_total),
           (SELECT COUNT(*) FROM stg_errors_flagged WHERE reject_reason = 'Unknown facility ID'),
           'Row quarantined; follow up with feed owner'
    UNION ALL
    SELECT 'V09', 'Facility-months expected but silent (no data or zero records)',
           (SELECT n FROM fm_total),
           (SELECT COUNT(*) FROM facility_month_status WHERE compliance_status = 'Silent'),
           'Flagged Silent; escalate per SOP when 30+ days'
    UNION ALL
    SELECT 'V10', 'Facilities with no data received in 30+ days (current)',
           (SELECT n FROM fac_total),
           (SELECT COUNT(*) FROM facility_status WHERE connection_status = 'Silent 30+ days'),
           'Escalate per SOP'
) v;

-- Add the percentage column in a second step so the CTE above stays readable
ALTER TABLE validation_summary ADD COLUMN pct_issues REAL;
UPDATE validation_summary
   SET pct_issues = CASE WHEN rows_checked > 0
                         THEN ROUND(issues_found * 1.0 / rows_checked, 4) END;
