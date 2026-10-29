-- 02_facility_month.sql
-- Build the facility x month status grid and the current facility status.
-- Output tables: dim_month, facility_month_status, facility_status

-- ---------------------------------------------------------------------------
-- Month dimension: every month from first to last month present in the data
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS dim_month;
CREATE TABLE dim_month AS
WITH RECURSIVE m(report_month) AS (
    SELECT MIN(report_month) FROM clean_submissions
    UNION ALL
    SELECT strftime('%Y-%m', date(report_month || '-01', '+1 month'))
    FROM m
    WHERE report_month < (SELECT MAX(report_month) FROM clean_submissions)
)
SELECT
    report_month,
    date(report_month || '-01', '+1 month', '-1 day') AS month_end
FROM m;

-- ---------------------------------------------------------------------------
-- Facility x month: one row for every facility that was onboarded by month-end
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS facility_month_status;
CREATE TABLE facility_month_status AS
WITH err AS (
    SELECT facility_id, report_month, SUM(error_count) AS total_errors
    FROM clean_errors
    GROUP BY facility_id, report_month
),
incomplete AS (
    -- facility-months whose only submission row was quarantined for a missing/invalid count
    SELECT DISTINCT facility_id, report_month
    FROM stg_submissions_flagged
    WHERE final_reject_reason IN ('Missing record count', 'Out-of-range record count')
),
grid AS (
    SELECT
        f.facility_id, f.facility_name, f.facility_type, f.county,
        m.report_month, m.month_end,
        s.record_count,
        s.last_received_date,
        COALESCE(e.total_errors, 0) AS total_errors,
        (i.facility_id IS NOT NULL) AS had_quarantined_row
    FROM facilities f
    JOIN dim_month m
      ON f.onboarding_date <= m.month_end
    LEFT JOIN clean_submissions s
      ON s.facility_id = f.facility_id AND s.report_month = m.report_month
    LEFT JOIN err e
      ON e.facility_id = f.facility_id AND e.report_month = m.report_month
    LEFT JOIN incomplete i
      ON i.facility_id = f.facility_id AND i.report_month = m.report_month
)
SELECT
    facility_id, facility_name, facility_type, county,
    report_month, month_end,
    COALESCE(record_count, 0) AS record_count,
    last_received_date,
    total_errors,
    CASE
        WHEN COALESCE(record_count, 0) > 0
            THEN ROUND(total_errors * 1.0 / record_count, 5)
    END AS error_rate,
    CASE
        WHEN record_count IS NULL AND had_quarantined_row THEN 'Data Incomplete'
        WHEN COALESCE(record_count, 0) = 0                THEN 'Silent'
        WHEN total_errors * 1.0 / record_count >
             (SELECT value FROM config WHERE key = 'error_rate_threshold')
                                                          THEN 'Elevated Errors'
        ELSE 'Compliant'
    END AS compliance_status
FROM grid;

-- ---------------------------------------------------------------------------
-- Current facility status as of the end of the latest month
-- ---------------------------------------------------------------------------
DROP TABLE IF EXISTS facility_status;
CREATE TABLE facility_status AS
WITH asof AS (
    SELECT MAX(month_end) AS as_of_date, MAX(report_month) AS latest_month FROM dim_month
),
last_recv AS (
    -- A row that arrived with a bad or missing count still proves the feed is alive,
    -- so quarantined rows with those reasons count as "received".
    SELECT facility_id, MAX(last_received_date) AS last_received_date
    FROM stg_submissions_flagged
    WHERE last_received_date IS NOT NULL
      AND (final_reject_reason IS NULL
           OR final_reject_reason IN ('Missing record count', 'Out-of-range record count'))
    GROUP BY facility_id
),
trailing AS (
    SELECT
        facility_id,
        SUM(record_count) AS records_3m,
        SUM(total_errors) AS errors_3m
    FROM facility_month_status
    WHERE report_month > strftime('%Y-%m', date((SELECT latest_month FROM asof) || '-01', '-3 months'))
      AND record_count > 0
    GROUP BY facility_id
)
SELECT
    f.facility_id, f.facility_name, f.facility_type, f.county, f.onboarding_date,
    (SELECT as_of_date FROM asof) AS as_of_date,
    l.last_received_date,
    CAST(julianday((SELECT as_of_date FROM asof)) - julianday(l.last_received_date) AS INTEGER)
        AS days_since_last_received,
    CASE
        WHEN l.last_received_date IS NULL THEN 'Never reported'
        WHEN julianday((SELECT as_of_date FROM asof)) - julianday(l.last_received_date) >
             (SELECT value FROM config WHERE key = 'silent_days') THEN 'Silent 30+ days'
        ELSE 'Reporting'
    END AS connection_status,
    cur.compliance_status AS latest_month_status,
    t.records_3m,
    t.errors_3m,
    CASE WHEN t.records_3m > 0 THEN ROUND(t.errors_3m * 1.0 / t.records_3m, 5) END AS error_rate_3m
FROM facilities f
LEFT JOIN last_recv l ON l.facility_id = f.facility_id
LEFT JOIN facility_month_status cur
       ON cur.facility_id = f.facility_id
      AND cur.report_month = (SELECT latest_month FROM asof)
LEFT JOIN trailing t ON t.facility_id = f.facility_id;
