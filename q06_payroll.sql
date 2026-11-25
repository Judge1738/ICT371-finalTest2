-- ICT371 Advanced Database
-- Question 6: Monthly Payroll Processing (PostgreSQL)
-- gross = basic_salary + allowance ; net = gross - deduction

DROP SCHEMA IF EXISTS q6_payroll CASCADE;
CREATE SCHEMA q6_payroll;
SET search_path = q6_payroll;

-- (a) Tables
CREATE TABLE employees (
  employee_id  SERIAL PRIMARY KEY,
  full_name    VARCHAR(100) NOT NULL,
  basic_salary NUMERIC(12,2) NOT NULL CHECK (basic_salary >= 0),
  allowance    NUMERIC(12,2) NOT NULL CHECK (allowance >= 0),
  deduction    NUMERIC(12,2) NOT NULL CHECK (deduction >= 0),
  active       BOOLEAN NOT NULL DEFAULT TRUE
);

CREATE TABLE payroll (
  payroll_id  SERIAL PRIMARY KEY,
  employee_id INT  NOT NULL REFERENCES employees(employee_id),
  pay_month   DATE NOT NULL,
  gross_pay   NUMERIC(12,2) NOT NULL CHECK (gross_pay >= 0),
  net_pay     NUMERIC(12,2) NOT NULL CHECK (net_pay >= 0),
  CONSTRAINT chk_pay_month_start CHECK (EXTRACT(DAY FROM pay_month) = 1),   -- first day of a month
  CONSTRAINT uq_employee_month UNIQUE (employee_id, pay_month)
);

CREATE TABLE salary_audit (
  audit_id    SERIAL PRIMARY KEY,
  employee_id INT NOT NULL REFERENCES employees(employee_id),
  old_salary  NUMERIC(12,2) NOT NULL,
  new_salary  NUMERIC(12,2) NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

-- (a) Employees: four active, one inactive from the start
INSERT INTO employees (full_name, basic_salary, allowance, deduction, active) VALUES
('Mulenga Chanda',  6000.00,  800.00, 500.00, TRUE),
('Natalie Mwila',   8500.00, 1000.00, 700.00, TRUE),
('Oliver Banda',    4500.00,  500.00, 400.00, TRUE),
('Patricia Lungu',  5200.00,  600.00, 450.00, TRUE),    -- becomes inactive after two months
('Quincy Sakala',   3000.00,  300.00, 200.00, FALSE);   -- inactive, never paid

-- (b) Function: net pay from current salary, allowance and deduction
CREATE OR REPLACE FUNCTION fn_net_pay(p_employee_id INT)
RETURNS NUMERIC AS $$
DECLARE
  v_basic NUMERIC;
  v_allow NUMERIC;
  v_deduct NUMERIC;
  v_net   NUMERIC;
BEGIN
  SELECT basic_salary, allowance, deduction INTO v_basic, v_allow, v_deduct
  FROM employees WHERE employee_id = p_employee_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown employee: %', p_employee_id;
  END IF;
  v_net := v_basic + v_allow - v_deduct;
  IF v_net < 0 THEN
    RAISE EXCEPTION 'Negative net pay (%) for employee %', v_net, p_employee_id;
  END IF;
  RETURN v_net;
END; $$ LANGUAGE plpgsql;

-- (d) Trigger: log only real basic_salary changes
CREATE OR REPLACE FUNCTION trg_salary_audit_fn() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO salary_audit (employee_id, old_salary, new_salary)
  VALUES (OLD.employee_id, OLD.basic_salary, NEW.basic_salary);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_salary_audit
AFTER UPDATE ON employees
FOR EACH ROW
WHEN (OLD.basic_salary IS DISTINCT FROM NEW.basic_salary)
EXECUTE FUNCTION trg_salary_audit_fn();

-- (c) Procedure: query FOR loop over active employees
CREATE OR REPLACE PROCEDURE pr_process_payroll(p_month DATE)
LANGUAGE plpgsql AS $$
DECLARE
  rec     RECORD;
  v_gross NUMERIC;
  v_net   NUMERIC;
BEGIN
  IF p_month IS NULL OR EXTRACT(DAY FROM p_month) <> 1 THEN
    RAISE EXCEPTION 'Payroll month must be the first day of a month, got %', p_month;
  END IF;

  FOR rec IN
    SELECT employee_id, basic_salary, allowance
    FROM employees
    WHERE active = TRUE
    ORDER BY employee_id
  LOOP
    v_gross := rec.basic_salary + rec.allowance;
    v_net   := fn_net_pay(rec.employee_id);   -- raises an error on a negative net: whole call fails

    -- insert the missing employee/month row; an existing row is left unchanged
    INSERT INTO payroll (employee_id, pay_month, gross_pay, net_pay)
    VALUES (rec.employee_id, p_month, v_gross, v_net)
    ON CONFLICT (employee_id, pay_month) DO NOTHING;
  END LOOP;
END; $$;

-- (a) Two payroll months, loaded through the procedure (all four active employees are paid)
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date);
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);

-- Employee 4 leaves: becomes inactive, but keeps historical payroll rows
UPDATE employees SET active = FALSE WHERE employee_id = 4;

-- (e) View: payroll joined to employee names (inactive employees' history stays visible)
CREATE VIEW v_payroll_report AS
SELECT p.payroll_id,
       e.full_name,
       p.pay_month,
       p.gross_pay,
       p.net_pay
FROM payroll p
JOIN employees e ON e.employee_id = p.employee_id
ORDER BY p.pay_month, e.full_name;

-- (f) Index on pay_month alone.
-- Justification: the unique index on (employee_id, pay_month) cannot help a report filtered
-- by pay_month across all employees, because pay_month is its second column. A single-column
-- index on pay_month lets that report find one month's rows directly, and it does not
-- duplicate the existing (employee_id, pay_month) unique index.
CREATE INDEX idx_payroll_pay_month ON payroll (pay_month);

-- ===== Tests =====
SELECT * FROM employees ORDER BY employee_id;
SELECT * FROM payroll ORDER BY pay_month, employee_id;   -- 8 rows (4 employees x 2 months)

SELECT fn_net_pay(1);    -- 6300.00 (6000 + 800 - 500)
SELECT fn_net_pay(2);    -- 8800.00
-- SELECT fn_net_pay(99);                                 -- error: unknown employee

SELECT * FROM v_payroll_report;    -- includes Patricia Lungu, now inactive

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM payroll
WHERE pay_month = (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date;
RESET enable_seqscan;

-- Trigger: a real salary change is logged; unchanged salary and other columns are not
UPDATE employees SET basic_salary = 6500.00 WHERE employee_id = 1;   -- logged (6000 -> 6500)
UPDATE employees SET basic_salary = 6500.00 WHERE employee_id = 1;   -- unchanged: no audit row
UPDATE employees SET allowance = 850.00     WHERE employee_id = 1;   -- not salary: no audit row
SELECT * FROM salary_audit ORDER BY audit_id;                         -- exactly 1 row

-- Rerun a processed month: existing rows stay unchanged, nothing is duplicated
CALL pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date);
SELECT * FROM payroll WHERE employee_id = 1 ORDER BY pay_month;      -- still gross 6800.00
SELECT COUNT(*) FROM payroll;                                          -- still 8

-- Procedure rejection: not a month-start date (should fail)
-- CALL pr_process_payroll(DATE '2026-10-15');

-- Whole call fails when one employee has a negative net (run all four lines together)
-- INSERT INTO employees (full_name, basic_salary, allowance, deduction, active)
--   VALUES ('Test Negative', 100, 0, 500, TRUE);
-- CALL pr_process_payroll(date_trunc('month', CURRENT_DATE)::date);   -- error; no rows inserted
-- SELECT COUNT(*) FROM payroll;                                       -- still 8
-- DELETE FROM employees WHERE full_name = 'Test Negative';

-- (g) Schedule: 02:00 on the 1st of each month, for the previous month (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('process_payroll_monthly', '0 2 1 * *',
  $$CALL q6_payroll.pr_process_payroll((date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date)$$);

-- Inspect the job and its run history
SELECT jobid, jobname, schedule, command, active FROM cron.job;
SELECT jobid, status, return_message, start_time, end_time
FROM cron.job_run_details
ORDER BY start_time DESC;
