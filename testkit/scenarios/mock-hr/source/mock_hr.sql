\connect autonox
CREATE SCHEMA IF NOT EXISTS mock_hr;
DROP TABLE IF EXISTS mock_hr.users;
CREATE TABLE mock_hr.users (
  user_id TEXT PRIMARY KEY,
  username TEXT NOT NULL,
  employee_id TEXT NOT NULL,
  email TEXT NOT NULL
);
INSERT INTO mock_hr.users VALUES ('hr-u001', 'ada', 'E001', 'ada@example.test');
GRANT USAGE ON SCHEMA mock_hr TO noxop;
GRANT SELECT ON mock_hr.users TO noxop;
