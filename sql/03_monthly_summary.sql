-- 03_monthly_summary.sql
-- Monthly KPI table and the aggregates that feed the dashboard.
-- Output tables: monthly_summary, error_by_type_month, error_by_facility_type, worst_offenders

-- ---------------------------------------------------------------------------
-- Monthly summary (one row per month)
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS monthly_summary;
CREATE TABLE monthly_summary AS
WITH base AS (
    SELECT
        report_month,
        COUNT(*)                                                         AS facilities_expected,
        SUM(compliance_status IN ('Compliant', 'Elevated Errors'))       AS facilities_reporting,
        SUM(compliance_status = 'Compliant')                             AS facilities_compliant,
        SUM(compliance_status = 'Elevated Errors')                       AS facilities_elevated_errors,
        SUM(compliance_status = 'Silent')                                AS facilities_silent,
        SUM(compliance_status = 'Data Incomplete')                       AS facilities_incomplete,
        SUM(record_count)                                                AS total_records,
        SUM(CASE WHEN record_count > 0 THEN total_errors ELSE 0 END)     AS total_errors
    FROM facility_month_status
    GROUP BY report_month
),
rates AS (
    SELECT
        *,
        ROUND(facilities_reporting * 1.0 / facilities_expected, 4) AS pct_reporting,
        ROUND(facilities_compliant * 1.0 / facilities_expected, 4) AS pct_compliant,
        CASE WHEN total_records > 0
             THEN ROUND(total_errors * 1.0 / total_records, 5) END AS error_rate
    FROM base
)
SELECT
    r.*,
    ROUND(r.pct_reporting - LAG(r.pct_reporting) OVER (ORDER BY r.report_month), 4) AS pct_reporting_mom_change,
    ROUND(r.pct_compliant - LAG(r.pct_compliant) OVER (ORDER BY r.report_month), 4) AS pct_compliant_mom_change,
    ROUND(r.error_rate    - LAG(r.error_rate)    OVER (ORDER BY r.report_month), 5) AS error_rate_mom_change,
    date(r.report_month || '-01') AS month_start_date
FROM rates r
ORDER BY r.report_month;

-- ---------------------------------------------------------------------------
-- Error rate by error type and month
-- Denominator = records from facilities that reported that month.
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS error_by_type_month;
CREATE TABLE error_by_type_month AS
SELECT
    e.report_month,
    e.error_type,
    SUM(e.error_count) AS error_count,
    (SELECT SUM(record_count) FROM facility_month_status f
      WHERE f.report_month = e.report_month AND f.record_count > 0) AS total_records,
    ROUND(SUM(e.error_count) * 1.0 /
          (SELECT SUM(record_count) FROM facility_month_status f
            WHERE f.report_month = e.report_month AND f.record_count > 0), 6) AS error_rate
FROM clean_errors e
JOIN facility_month_status f
  ON f.facility_id = e.facility_id AND f.report_month = e.report_month AND f.record_count > 0
GROUP BY e.report_month, e.error_type
ORDER BY e.report_month, e.error_type;

-- ---------------------------------------------------------------------------
-- Error rate by facility type and month
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS error_by_facility_type;
CREATE TABLE error_by_facility_type AS
SELECT
    facility_type,
    report_month,
    COUNT(*)                          AS facilities_reporting,
    SUM(record_count)                 AS total_records,
    SUM(total_errors)                 AS total_errors,
    ROUND(SUM(total_errors) * 1.0 / SUM(record_count), 5) AS error_rate
FROM facility_month_status
WHERE record_count > 0
GROUP BY facility_type, report_month
ORDER BY report_month, facility_type;

-- ---------------------------------------------------------------------------
-- Top-10 worst-offender facilities: highest error rate over the trailing 3 months
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS worst_offenders;
CREATE TABLE worst_offenders AS
WITH ranked AS (
    SELECT
        fs.facility_id, fs.facility_name, fs.facility_type, fs.county,
        fs.records_3m, fs.errors_3m, fs.error_rate_3m,
        RANK() OVER (ORDER BY fs.error_rate_3m DESC) AS offender_rank
    FROM facility_status fs
    WHERE fs.records_3m > 0
),
latest AS (SELECT MAX(report_month) AS latest_month FROM dim_month),
top_type AS (
    SELECT
        e.facility_id,
        e.error_type,
        SUM(e.error_count) AS cnt,
        ROW_NUMBER() OVER (PARTITION BY e.facility_id ORDER BY SUM(e.error_count) DESC) AS rn
    FROM clean_errors e
    WHERE e.report_month > strftime('%Y-%m', date((SELECT latest_month FROM latest) || '-01', '-3 months'))
    GROUP BY e.facility_id, e.error_type
)
SELECT
    r.offender_rank,
    r.facility_id, r.facility_name, r.facility_type, r.county,
    r.records_3m, r.errors_3m, r.error_rate_3m,
    t.error_type AS top_error_type
FROM ranked r
LEFT JOIN top_type t ON t.facility_id = r.facility_id AND t.rn = 1
WHERE r.offender_rank <= 10
ORDER BY r.offender_rank;
