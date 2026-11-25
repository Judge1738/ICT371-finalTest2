-- ICT371 Advanced Database
-- Question 2: University Fee Payments (PostgreSQL)

DROP SCHEMA IF EXISTS q2_fees CASCADE;
CREATE SCHEMA q2_fees;
SET search_path = q2_fees;

-- (a) Tables and constraints
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL,
  fee_due        NUMERIC(12,2) NOT NULL CHECK (fee_due >= 0)
);

CREATE TABLE payments (
  payment_id SERIAL PRIMARY KEY,
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL CHECK (amount > 0),
  paid_on    DATE NOT NULL
);

CREATE TABLE payment_audit (
  audit_id   SERIAL PRIMARY KEY,
  payment_id INT NOT NULL REFERENCES payments(payment_id),
  student_id INT NOT NULL REFERENCES students(student_id),
  amount     NUMERIC(12,2) NOT NULL,
  logged_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_collections (
  collection_date DATE PRIMARY KEY,
  payment_count   INT NOT NULL,
  total_amount    NUMERIC(14,2) NOT NULL
);

-- (a) Three students with different fee balances
INSERT INTO students (student_number, full_name, fee_due) VALUES
('STU001', 'Alice Mwansa', 5000.00),
('STU002', 'Brian Phiri',  4000.00),
('STU003', 'Chola Banda',  3000.00);   -- no payments yet

-- (b) Function: fee_due minus total payments
CREATE OR REPLACE FUNCTION fn_fee_balance(p_student_id INT)
RETURNS NUMERIC AS $$
DECLARE v_fee NUMERIC;
BEGIN
  SELECT fee_due INTO v_fee FROM students WHERE student_id = p_student_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  RETURN v_fee - COALESCE((SELECT SUM(amount) FROM payments
                           WHERE student_id = p_student_id), 0);
END; $$ LANGUAGE plpgsql;

-- (c) Procedure: validates, then inserts the payment only
CREATE OR REPLACE PROCEDURE pr_receive_payment(p_student_id INT, p_amount NUMERIC, p_paid_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_balance NUMERIC; v_dummy INT;
BEGIN
  IF p_amount IS NULL OR p_amount <= 0 THEN
    RAISE EXCEPTION 'Invalid payment amount: %', p_amount;
  END IF;
  IF p_paid_on IS NULL THEN
    RAISE EXCEPTION 'Payment date is required';
  END IF;
  -- lock the student row so two payments cannot overpay at the same time
  SELECT student_id INTO v_dummy FROM students
  WHERE student_id = p_student_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  v_balance := fn_fee_balance(p_student_id);
  IF p_amount > v_balance THEN
    RAISE EXCEPTION 'Payment % exceeds outstanding balance %', p_amount, v_balance;
  END IF;
  INSERT INTO payments (student_id, amount, paid_on)
  VALUES (p_student_id, p_amount, p_paid_on);
  -- fee_due is not changed; no audit insert here (the trigger does it)
END; $$;

-- (d) Trigger: automatic audit row after every payment insert
CREATE OR REPLACE FUNCTION trg_payment_audit_fn() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO payment_audit (payment_id, student_id, amount, logged_at)
  VALUES (NEW.payment_id, NEW.student_id, NEW.amount, now());
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_payment_audit
AFTER INSERT ON payments
FOR EACH ROW
EXECUTE FUNCTION trg_payment_audit_fn();

-- (a) Six payments loaded through the procedure (trigger is already installed)
CALL pr_receive_payment(1, 1000.00, CURRENT_DATE - 3);
CALL pr_receive_payment(1, 1500.00, CURRENT_DATE - 2);
CALL pr_receive_payment(1,  500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 3);
CALL pr_receive_payment(2, 1500.00, CURRENT_DATE - 1);
CALL pr_receive_payment(2, 1000.00, CURRENT_DATE - 1);   -- STU002 fully settled

-- (e) View: only students who still owe fees
CREATE VIEW v_fee_balances AS
SELECT s.student_number,
       s.full_name,
       s.fee_due - COALESCE(SUM(p.amount), 0) AS outstanding_balance
FROM students s
LEFT JOIN payments p ON p.student_id = s.student_id
GROUP BY s.student_id, s.student_number, s.full_name, s.fee_due
HAVING s.fee_due - COALESCE(SUM(p.amount), 0) > 0;

-- (f) Composite index: equality on student_id first, then range on paid_on
CREATE INDEX idx_payments_student_paid_on ON payments (student_id, paid_on);

-- (g) Refresh procedure (idempotent: rerun replaces the row)
CREATE OR REPLACE PROCEDURE pr_refresh_collections(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_collections (collection_date, payment_count, total_amount)
  SELECT p_day, COUNT(*), COALESCE(SUM(amount), 0)
  FROM payments WHERE paid_on = p_day
  ON CONFLICT (collection_date) DO UPDATE
  SET payment_count = EXCLUDED.payment_count,
      total_amount  = EXCLUDED.total_amount;
END; $$;

-- ===== Tests =====
SELECT * FROM students ORDER BY student_id;
SELECT * FROM payments ORDER BY payment_id;
SELECT * FROM payment_audit ORDER BY audit_id;     -- 6 rows written by the trigger

SELECT fn_fee_balance(1);   -- 2000.00
SELECT fn_fee_balance(2);   -- 0.00
SELECT fn_fee_balance(3);   -- 3000.00 (no payments, full fee)
-- SELECT fn_fee_balance(99);                       -- error: unknown student

-- Invalid payments (run one at a time; each should fail)
-- CALL pr_receive_payment(1, NULL, CURRENT_DATE);
-- CALL pr_receive_payment(1, 0, CURRENT_DATE);
-- CALL pr_receive_payment(1, -50, CURRENT_DATE);
-- CALL pr_receive_payment(1, 2500, CURRENT_DATE);  -- above outstanding balance 2000
-- CALL pr_receive_payment(99, 100, CURRENT_DATE);  -- unknown student

SELECT * FROM v_fee_balances;                       -- STU001 and STU003 only

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM payments
WHERE student_id = 1 AND paid_on BETWEEN CURRENT_DATE - 3 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_collections(CURRENT_DATE - 1);
CALL pr_refresh_collections(CURRENT_DATE - 1);      -- rerun: row replaced, not duplicated
SELECT * FROM daily_collections;

-- Schedule: daily at 01:00 for the previous day (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_collections_daily', '0 1 * * *',
  $$CALL q2_fees.pr_refresh_collections(CURRENT_DATE - 1)$$);
SELECT jobid, schedule, command, jobname FROM cron.job;
