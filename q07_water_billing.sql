-- ICT371 Advanced Database
-- Question 7: Water Meter Readings and Billing (PostgreSQL)
-- Tariff: first 10 units at K5 each, units above 10 at K8 each; zero units = K0.

DROP SCHEMA IF EXISTS q7_water CASCADE;
CREATE SCHEMA q7_water;
SET search_path = q7_water;

-- (a) Tables
CREATE TABLE customers (
  customer_id SERIAL PRIMARY KEY,
  full_name   VARCHAR(100) NOT NULL
);

CREATE TABLE readings (
  reading_id       SERIAL PRIMARY KEY,
  customer_id      INT  NOT NULL REFERENCES customers(customer_id),
  reading_month    DATE NOT NULL,
  previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
  current_reading  NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
  CONSTRAINT chk_reading_month_start CHECK (EXTRACT(DAY FROM reading_month) = 1),
  CONSTRAINT uq_customer_month UNIQUE (customer_id, reading_month)
);

CREATE TABLE bills (
  bill_id     SERIAL PRIMARY KEY,
  reading_id  INT NOT NULL UNIQUE REFERENCES readings(reading_id),
  charge      NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
  amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0,
  due_on      DATE NOT NULL,
  CONSTRAINT chk_paid_range CHECK (amount_paid >= 0 AND amount_paid <= charge)
);

CREATE TABLE receivable_snapshot (
  snapshot_date DATE PRIMARY KEY,
  total_due     NUMERIC(14,2) NOT NULL
);

INSERT INTO customers (full_name) VALUES
('Agness Mukuka'), ('Benson Nkandu'), ('Catherine Zulu');

-- (b) Function: two tariff bands, exact two-decimal result
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC AS $$
BEGIN
  IF p_units IS NULL THEN
    RAISE EXCEPTION 'Consumption cannot be NULL';
  END IF;
  IF p_units < 0 THEN
    RAISE EXCEPTION 'Consumption cannot be negative: %', p_units;
  END IF;
  RETURN ROUND( LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8, 2 );
END; $$ LANGUAGE plpgsql;

-- (d) Trigger: reject current_reading below previous_reading (also for direct SQL imports)
CREATE OR REPLACE FUNCTION trg_reading_check_fn() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.current_reading < NEW.previous_reading THEN
    RAISE EXCEPTION 'Current reading (%) is below previous reading (%)',
      NEW.current_reading, NEW.previous_reading;
  END IF;
  RETURN NEW;   -- the exception above aborts the statement, so a rejected reading is never stored
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_reading_check
BEFORE INSERT OR UPDATE ON readings
FOR EACH ROW
EXECUTE FUNCTION trg_reading_check_fn();

-- (a) Six readings (trigger already active): zero, exactly 10, and above 10 units
INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading) VALUES
(1, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 100, 100),    -- 0 units
(1, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  100, 110),    -- exactly 10 units
(2, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 200, 215),    -- 15 units
(2, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  215, 223),    -- 8 units
(3, (date_trunc('month', CURRENT_DATE) - INTERVAL '2 months')::date, 50,  72),     -- 22 units
(3, (date_trunc('month', CURRENT_DATE) - INTERVAL '1 month')::date,  72,  79.5);   -- 7.5 units

-- (c) Procedure: derive consumption, call the function, insert the bill
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id INT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_prev   NUMERIC;
  v_curr   NUMERIC;
  v_charge NUMERIC;
BEGIN
  IF p_due_on IS NULL THEN
    RAISE EXCEPTION 'Due date is required';
  END IF;
  SELECT previous_reading, current_reading INTO v_prev, v_curr
  FROM readings WHERE reading_id = p_reading_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown reading: %', p_reading_id;
  END IF;
  IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
    RAISE EXCEPTION 'Reading % already has a bill', p_reading_id;
  END IF;
  v_charge := fn_water_charge(v_curr - v_prev);
  INSERT INTO bills (reading_id, charge, amount_paid, due_on)
  VALUES (p_reading_id, v_charge, 0, p_due_on);
END; $$;

-- Bills for all six readings, generated through the procedure
CALL pr_generate_bill(1, CURRENT_DATE - 20);
CALL pr_generate_bill(2, CURRENT_DATE - 5);
CALL pr_generate_bill(3, CURRENT_DATE - 20);
CALL pr_generate_bill(4, CURRENT_DATE + 10);
CALL pr_generate_bill(5, CURRENT_DATE - 20);
CALL pr_generate_bill(6, CURRENT_DATE + 10);

-- Some payments (amount_paid stays between 0 and charge)
UPDATE bills SET amount_paid = 90 WHERE bill_id = 3;    -- fully paid
UPDATE bills SET amount_paid = 50 WHERE bill_id = 5;    -- partly paid, overdue
UPDATE bills SET amount_paid = 20 WHERE bill_id = 4;    -- partly paid, not yet due

-- (e) View: overdue and not fully paid
CREATE VIEW v_overdue_bills AS
SELECT b.bill_id,
       c.full_name AS customer_name,
       b.due_on,
       b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r  ON r.reading_id  = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE
  AND b.amount_paid < b.charge;

-- (f) Partial index: only bills that are not fully paid, searched by due date
CREATE INDEX idx_bills_unpaid_due ON bills (due_on) WHERE amount_paid < charge;
-- Justification: overdue searches only look at unpaid bills and filter on due_on. The partial
-- index holds just the unpaid bills (fully paid ones are left out), so it stays small, and the
-- due_on ordering lets a "due before today" search read one range of the index.

-- (g) Refresh procedure: today's total unpaid balance, replaced on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO receivable_snapshot (snapshot_date, total_due)
  SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
  FROM bills
  ON CONFLICT (snapshot_date) DO UPDATE
  SET total_due = EXCLUDED.total_due;
END; $$;

-- ===== Tests =====
SELECT * FROM customers ORDER BY customer_id;
SELECT * FROM readings ORDER BY reading_id;      -- 6 rows

SELECT fn_water_charge(0);      -- 0.00
SELECT fn_water_charge(10);     -- 50.00
SELECT fn_water_charge(15);     -- 90.00
SELECT fn_water_charge(7.5);    -- 37.50
-- SELECT fn_water_charge(NULL);                  -- error: NULL consumption
-- SELECT fn_water_charge(-1);                    -- error: negative consumption

SELECT * FROM bills ORDER BY bill_id;            -- charges 0, 50, 90, 40, 146, 37.50

-- Procedure rejections (run one at a time; each should fail)
-- CALL pr_generate_bill(99, CURRENT_DATE);       -- unknown reading
-- CALL pr_generate_bill(1, CURRENT_DATE);        -- reading 1 already has a bill

-- Trigger rejections (each should fail, and the reading must not be stored)
-- INSERT INTO readings (customer_id, reading_month, previous_reading, current_reading)
--   VALUES (1, (date_trunc('month', CURRENT_DATE))::date, 110, 105);
-- UPDATE readings SET current_reading = 90 WHERE reading_id = 2;
-- SELECT COUNT(*) FROM readings;                 -- still 6

SELECT * FROM v_overdue_bills;                   -- bills 2 (50.00) and 5 (96.00)

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM bills
WHERE amount_paid < charge AND due_on < CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_receivables();
CALL pr_refresh_receivables();                   -- rerun: today's row replaced, not duplicated
SELECT * FROM receivable_snapshot;               -- total_due 203.50

-- (g) Schedule: daily at 00:30
-- Uses pg_cron. If pg_cron is not installed on this server, this block prints a notice with the
-- exact job instead of failing.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_receivables_daily', '30 0 * * *',
      $cmd$CALL q7_water.pr_refresh_receivables()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron is not installed on this server. Job to schedule: cron.schedule(%, %, %)',
      'refresh_receivables_daily', '30 0 * * *', $cmd$CALL q7_water.pr_refresh_receivables()$cmd$;
  END IF;
END $do$;

-- Where pg_cron is installed, inspect the job and its run history with:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC;
