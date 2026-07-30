\connect autonox
CREATE SCHEMA IF NOT EXISTS mock_hr;
DROP TABLE IF EXISTS mock_hr.users;
CREATE TABLE mock_hr.users (
  user_id     TEXT PRIMARY KEY,
  username    TEXT NOT NULL,
  employee_id TEXT NOT NULL,
  first_name  TEXT NOT NULL,
  last_name   TEXT NOT NULL,
  email       TEXT NOT NULL,
  department  TEXT NOT NULL,
  job_title   TEXT NOT NULL
);
INSERT INTO mock_hr.users VALUES
  ('hr-u001', 'ada',   'E001', 'Ada',   'Lovelace', 'ada@example.test',   'Engineering', 'Principal Engineer'),
  ('hr-u002', 'grace', 'E002', 'Grace', 'Hopper',   'grace@example.test', 'Engineering', 'Engineering Manager'),
  ('hr-u003', 'alan',  'E003', 'Alan',  'Turing',   'alan@example.test',  'Research',    'Research Lead');
GRANT USAGE ON SCHEMA mock_hr TO noxop;
GRANT SELECT ON mock_hr.users TO noxop;
