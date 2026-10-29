-- 00_config.sql
-- Thresholds used by the validation and compliance logic.
-- Change a value here and rerun the pipeline; nothing else needs editing.

DROP TABLE IF EXISTS config;
CREATE TABLE config (
    key   TEXT PRIMARY KEY,
    value REAL NOT NULL,
    note  TEXT
);

INSERT INTO config (key, value, note) VALUES
    ('error_rate_threshold', 0.03,   'Facility-month error rate above this is flagged "Elevated Errors"'),
    ('silent_days',          30,     'No data received for more than this many days = "Silent 30+ days"'),
    ('max_record_count',     500000, 'Monthly record counts above this are treated as out-of-range'),
    ('min_record_count',     0,      'Monthly record counts below this are treated as out-of-range');
