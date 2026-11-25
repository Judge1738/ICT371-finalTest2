-- ICT371 Advanced Database
-- Question 10: Scholarship Application Assessment (PostgreSQL)
-- Eligible only when: age 18 to 25 inclusive, monthly income <= K3,000, average mark >= 70.

DROP SCHEMA IF EXISTS q10_scholarship CASCADE;
CREATE SCHEMA q10_scholarship;
SET search_path = q10_scholarship;

-- (a) Tables
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE applications (
  application_id     SERIAL PRIMARY KEY,
  student_id         INT NOT NULL REFERENCES students(student_id),
  age_at_application INT NOT NULL CHECK (age_at_application > 0),
  monthly_income     NUMERIC(10,2) NOT NULL CHECK (monthly_income >= 0),
  average_mark       NUMERIC(5,2)  NOT NULL CHECK (average_mark BETWEEN 0 AND 100),
  submitted_on       DATE NOT NULL,
  status             VARCHAR(10) NOT NULL DEFAULT 'PENDING',
  CONSTRAINT chk_app_status CHECK (status IN ('PENDING','APPROVED','REJECTED'))
);

CREATE TABLE decision_audit (
  audit_id       SERIAL PRIMARY KEY,
  application_id INT NOT NULL REFERENCES applications(application_id),
  old_status     VARCHAR(10) NOT NULL,
  new_status     VARCHAR(10) NOT NULL,
  changed_at     TIMESTAMP NOT NULL DEFAULT now()
);

INSERT INTO students (student_number, full_name) VALUES
('S001', 'Nalishuwa Mwanza'),
('S002', 'Chanda Mubanga'),
('S003', 'Thandiwe Daka');

-- (a) Six PENDING applications: qualifying, non-qualifying and boundary cases
INSERT INTO applications (student_id, age_at_application, monthly_income, average_mark, submitted_on, status) VALUES
(1, 18, 2500.00, 75.00, CURRENT_DATE - 20, 'PENDING'),   -- 1: qualifies (lowest age)
(1, 25, 3000.00, 70.00, CURRENT_DATE - 18, 'PENDING'),   -- 2: qualifies (every boundary value)
(2, 26, 1000.00, 85.00, CURRENT_DATE - 15, 'PENDING'),   -- 3: age too high
(2, 22, 3000.01, 80.00, CURRENT_DATE - 12, 'PENDING'),   -- 4: income just above K3,000
(3, 17, 1500.00, 90.00, CURRENT_DATE - 9,  'PENDING'),   -- 5: age too low
(3, 21, 2000.00, 69.99, CURRENT_DATE - 5,  'PENDING');   -- 6: mark just below 70

-- (b) Function: all three eligibility rules
CREATE OR REPLACE FUNCTION fn_scholarship_eligible(p_age INT, p_income NUMERIC, p_mark NUMERIC)
RETURNS BOOLEAN AS $$
BEGIN
  IF p_age IS NULL OR p_income IS NULL OR p_mark IS NULL THEN
    RAISE EXCEPTION 'Age, income and mark must not be NULL';
  END IF;
  IF p_income < 0 THEN
    RAISE EXCEPTION 'Income cannot be negative: %', p_income;
  END IF;
  IF p_age <= 0 THEN
    RAISE EXCEPTION 'Age must be positive: %', p_age;
  END IF;
  IF p_mark < 0 OR p_mark > 100 THEN
    RAISE EXCEPTION 'Mark must be between 0 and 100: %', p_mark;
  END IF;
  RETURN p_age BETWEEN 18 AND 25
     AND p_income <= 3000
     AND p_mark >= 70;
END; $$ LANGUAGE plpgsql;

-- (c) Procedure: assess one PENDING application
CREATE OR REPLACE PROCEDURE pr_assess_application(p_application_id INT)
LANGUAGE plpgsql AS $$
DECLARE
  v_status VARCHAR;
  v_age    INT;
  v_income NUMERIC;
  v_mark   NUMERIC;
BEGIN
  SELECT status, age_at_application, monthly_income, average_mark
  INTO v_status, v_age, v_income, v_mark
  FROM applications WHERE application_id = p_application_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown application: %', p_application_id;
  END IF;
  IF v_status <> 'PENDING' THEN
    RAISE EXCEPTION 'Application % was already assessed (status: %)', p_application_id, v_status;
  END IF;

  UPDATE applications
  SET status = CASE WHEN fn_scholarship_eligible(v_age, v_income, v_mark)
                    THEN 'APPROVED' ELSE 'REJECTED' END
  WHERE application_id = p_application_id;
END; $$;

-- (d) Trigger: record only real status changes
CREATE OR REPLACE FUNCTION trg_decision_audit_fn() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO decision_audit (application_id, old_status, new_status, changed_at)
  VALUES (OLD.application_id, OLD.status, NEW.status, now());
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_decision_audit
AFTER UPDATE ON applications
FOR EACH ROW
WHEN (OLD.status IS DISTINCT FROM NEW.status)
EXECUTE FUNCTION trg_decision_audit_fn();

-- (e) View: approved applicants only, income not exposed
CREATE VIEW v_approved_applicants AS
SELECT s.student_number,
       s.full_name,
       a.average_mark,
       a.status
FROM applications a
JOIN students s ON s.student_id = a.student_id
WHERE a.status = 'APPROVED';

-- (f) Composite index: status (equality) first, then submitted_on (range)
CREATE INDEX idx_applications_status_submitted ON applications (status, submitted_on);
-- Justification: the search fixes one status and a submitted_on date range. With status first the
-- index jumps to that status; submitted_on second keeps those entries in date order, so the
-- range is read as one contiguous slice.

-- (g) Batch procedure: query FOR loop over PENDING applications only
CREATE OR REPLACE PROCEDURE pr_assess_pending()
LANGUAGE plpgsql AS $$
DECLARE
  rec RECORD;
BEGIN
  FOR rec IN
    SELECT application_id
    FROM applications
    WHERE status = 'PENDING'
    ORDER BY application_id
  LOOP
    CALL pr_assess_application(rec.application_id);
  END LOOP;
END; $$;

-- ===== Tests =====
SELECT * FROM students ORDER BY student_id;
SELECT * FROM applications ORDER BY application_id;     -- 6 PENDING rows

SELECT fn_scholarship_eligible(18, 2500, 75);      -- true  (age boundary)
SELECT fn_scholarship_eligible(25, 3000, 70);      -- true  (all boundaries)
SELECT fn_scholarship_eligible(26, 1000, 85);      -- false (age)
SELECT fn_scholarship_eligible(22, 3000.01, 80);   -- false (income)
SELECT fn_scholarship_eligible(21, 2000, 69.99);   -- false (mark)
-- SELECT fn_scholarship_eligible(NULL, 1000, 80);  -- error: NULL input
-- SELECT fn_scholarship_eligible(20, -1, 80);      -- error: negative income
-- SELECT fn_scholarship_eligible(0, 1000, 80);     -- error: non-positive age
-- SELECT fn_scholarship_eligible(20, 1000, 101);   -- error: mark out of range

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM applications
WHERE status = 'PENDING' AND submitted_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

-- Assess one application with the procedure
CALL pr_assess_application(1);
SELECT * FROM decision_audit ORDER BY audit_id;          -- 1 row: PENDING -> APPROVED

-- Assess every remaining PENDING application with the batch procedure
CALL pr_assess_pending();
SELECT * FROM applications ORDER BY application_id;      -- 1 and 2 APPROVED, 3 to 6 REJECTED
SELECT * FROM decision_audit ORDER BY audit_id;          -- 6 rows

-- Rerun: completed applications are not reassessed and no audit entries are duplicated
CALL pr_assess_pending();
SELECT COUNT(*) FROM decision_audit;                     -- still 6

-- An update that leaves the status unchanged creates no audit row
UPDATE applications SET status = status WHERE application_id = 1;
SELECT COUNT(*) FROM decision_audit;                     -- still 6

SELECT * FROM v_approved_applicants;                     -- S001 (75.00) and S001 (70.00)

-- Procedure rejections (run one at a time; each should fail)
-- CALL pr_assess_application(99);                       -- unknown application
-- CALL pr_assess_application(1);                        -- already assessed

-- (g) Schedule: every Monday at 08:00
-- Uses pg_cron. If pg_cron is not installed on this server, this block prints a notice with the
-- exact job instead of failing.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('assess_pending_weekly', '0 8 * * 1',
      $cmd$CALL q10_scholarship.pr_assess_pending()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron is not installed on this server. Job to schedule: cron.schedule(%, %, %)',
      'assess_pending_weekly', '0 8 * * 1', $cmd$CALL q10_scholarship.pr_assess_pending()$cmd$;
  END IF;
END $do$;

-- Where pg_cron is installed, inspect the job and its run history with:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC;
