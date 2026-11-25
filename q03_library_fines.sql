-- ICT371 Advanced Database
-- Question 3: Library Returns and Overdue Fines (PostgreSQL)
-- Fine rule: K2 per day after the due date; return on the due date = no fine.

DROP SCHEMA IF EXISTS q3_library CASCADE;
CREATE SCHEMA q3_library;
SET search_path = q3_library;

-- (a) Tables
CREATE TABLE books (
  book_id SERIAL PRIMARY KEY,
  title   VARCHAR(150) NOT NULL
);

CREATE TABLE loans (
  loan_id       SERIAL PRIMARY KEY,
  book_id       INT NOT NULL REFERENCES books(book_id),
  borrower_name VARCHAR(100) NOT NULL,
  borrowed_on   DATE NOT NULL,
  due_on        DATE NOT NULL,
  returned_on   DATE NULL,
  fine_amount   NUMERIC(10,2) NOT NULL DEFAULT 0 CHECK (fine_amount >= 0),
  CONSTRAINT chk_due_after_borrow CHECK (due_on >= borrowed_on),
  CONSTRAINT chk_return_after_borrow CHECK (returned_on IS NULL OR returned_on >= borrowed_on)
);

CREATE TABLE loan_audit (
  audit_id         SERIAL PRIMARY KEY,
  loan_id          INT NOT NULL REFERENCES loans(loan_id),
  old_returned_on  DATE NULL,
  new_returned_on  DATE NULL,
  changed_at       TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE overdue_summary (
  snapshot_date DATE PRIMARY KEY,
  overdue_count INT NOT NULL,
  total_fine    NUMERIC(12,2) NOT NULL
);

-- (a) Seed data: three books, six loans (all start open; two are returned below
--     through the procedure once the trigger is installed)
INSERT INTO books (title) VALUES
('Database System Concepts'),
('Operating Systems'),
('Computer Networks');

INSERT INTO loans (book_id, borrower_name, borrowed_on, due_on) VALUES
(1, 'Mary Zulu',    CURRENT_DATE - 20, CURRENT_DATE - 6),   -- 1: open, overdue 6 days
(1, 'John Tembo',   CURRENT_DATE - 10, CURRENT_DATE + 4),   -- 2: open, not yet due
(2, 'Grace Mumba',  CURRENT_DATE - 30, CURRENT_DATE - 16),  -- 3: will be returned on due date
(2, 'Peter Chanda', CURRENT_DATE - 25, CURRENT_DATE - 15),  -- 4: will be returned late
(3, 'Ruth Lungu',   CURRENT_DATE - 8,  CURRENT_DATE - 2),   -- 5: open, overdue 2 days
(3, 'Sam Kaonga',   CURRENT_DATE - 5,  CURRENT_DATE + 9);   -- 6: open, not yet due

-- (b) Function: K2 x overdue days, minimum zero
CREATE OR REPLACE FUNCTION fn_loan_fine(p_loan_id INT, p_as_of DATE)
RETURNS NUMERIC AS $$
DECLARE
  v_due      DATE;
  v_returned DATE;
  v_end      DATE;
BEGIN
  IF p_as_of IS NULL THEN
    RAISE EXCEPTION 'As-of date is required';
  END IF;
  SELECT due_on, returned_on INTO v_due, v_returned
  FROM loans WHERE loan_id = p_loan_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  -- earlier of as-of date and return date (if the loan has been returned)
  v_end := LEAST(p_as_of, COALESCE(v_returned, p_as_of));
  RETURN 2.00 * GREATEST(v_end - v_due, 0);
END; $$ LANGUAGE plpgsql;

-- (c) Procedure: store return date and final fine together
CREATE OR REPLACE PROCEDURE pr_return_loan(p_loan_id INT, p_returned_on DATE)
LANGUAGE plpgsql AS $$
DECLARE
  v_borrowed DATE;
  v_returned DATE;
BEGIN
  SELECT borrowed_on, returned_on INTO v_borrowed, v_returned
  FROM loans WHERE loan_id = p_loan_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown loan: %', p_loan_id;
  END IF;
  IF v_returned IS NOT NULL THEN
    RAISE EXCEPTION 'Loan % is already returned', p_loan_id;
  END IF;
  IF p_returned_on IS NULL THEN
    RAISE EXCEPTION 'Return date is required';
  END IF;
  IF p_returned_on < v_borrowed THEN
    RAISE EXCEPTION 'Return date % is before borrowed date %', p_returned_on, v_borrowed;
  END IF;
  -- one UPDATE stores the date and the final fine together
  UPDATE loans
  SET returned_on = p_returned_on,
      fine_amount = fn_loan_fine(p_loan_id, p_returned_on)
  WHERE loan_id = p_loan_id;
END; $$;

-- (d) Trigger: log only real changes to returned_on
CREATE OR REPLACE FUNCTION trg_loan_audit_fn() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO loan_audit (loan_id, old_returned_on, new_returned_on)
  VALUES (OLD.loan_id, OLD.returned_on, NEW.returned_on);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_loan_audit
AFTER UPDATE ON loans
FOR EACH ROW
WHEN (OLD.returned_on IS DISTINCT FROM NEW.returned_on)
EXECUTE FUNCTION trg_loan_audit_fn();

-- (a) Returned loans, loaded through the procedure (trigger now active)
CALL pr_return_loan(3, CURRENT_DATE - 16);   -- on the due date: fine 0
CALL pr_return_loan(4, CURRENT_DATE - 10);   -- 5 days late: fine 10

-- (e) View: unreturned loans due before today, with the fine as of today
CREATE VIEW v_overdue_loans AS
SELECT l.loan_id,
       b.title,
       l.borrower_name,
       l.due_on,
       fn_loan_fine(l.loan_id, CURRENT_DATE) AS fine_as_of_today
FROM loans l
JOIN books b ON b.book_id = l.book_id
WHERE l.returned_on IS NULL
  AND l.due_on < CURRENT_DATE;

-- (f) Partial index: only unreturned loans are indexed, keyed by book_id
CREATE INDEX idx_loans_book_unreturned ON loans (book_id) WHERE returned_on IS NULL;
-- Justification: the search is "unreturned loans for one book". A partial index is small
-- (returned loans are excluded) and book_id equality finds the rows directly.

-- (g) Refresh procedure: loans unreturned as of p_as_of and the sum of their fines
--     (a loan returned after p_as_of was still unreturned on that date)
CREATE OR REPLACE PROCEDURE pr_refresh_overdue(p_as_of DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO overdue_summary (snapshot_date, overdue_count, total_fine)
  SELECT p_as_of,
         COUNT(*),
         COALESCE(SUM(fn_loan_fine(loan_id, p_as_of)), 0)
  FROM loans
  WHERE borrowed_on <= p_as_of
    AND (returned_on IS NULL OR returned_on > p_as_of)
  ON CONFLICT (snapshot_date) DO UPDATE
  SET overdue_count = EXCLUDED.overdue_count,
      total_fine    = EXCLUDED.total_fine;
END; $$;

-- ===== Tests =====
SELECT * FROM books ORDER BY book_id;
SELECT * FROM loans ORDER BY loan_id;        -- loans 3 and 4 returned, fines 0.00 and 10.00

SELECT fn_loan_fine(1, CURRENT_DATE);        -- 12.00 (open, 6 days overdue)
SELECT fn_loan_fine(3, CURRENT_DATE);        -- 0.00  (returned on due date)
SELECT fn_loan_fine(4, CURRENT_DATE);        -- 10.00 (stops at return date)
SELECT fn_loan_fine(4, CURRENT_DATE - 12);   -- 6.00  (earlier as-of date is used)
-- SELECT fn_loan_fine(99, CURRENT_DATE);    -- error: unknown loan

-- Procedure rejections (run one at a time; each should fail)
-- CALL pr_return_loan(99, CURRENT_DATE);            -- unknown loan
-- CALL pr_return_loan(3, CURRENT_DATE);             -- already returned
-- CALL pr_return_loan(2, CURRENT_DATE - 100);       -- before borrowed_on

SELECT * FROM loan_audit ORDER BY audit_id;  -- 2 rows
UPDATE loans SET returned_on = returned_on WHERE loan_id = 3;   -- unchanged date
SELECT COUNT(*) FROM loan_audit;             -- still 2 (no new audit row)

SELECT * FROM v_overdue_loans;               -- loans 1 and 5

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM loans WHERE book_id = 1 AND returned_on IS NULL;
RESET enable_seqscan;

CALL pr_refresh_overdue(CURRENT_DATE);
CALL pr_refresh_overdue(CURRENT_DATE);       -- rerun: same row replaced, not duplicated
SELECT * FROM overdue_summary;               -- 4 unreturned loans, total fine 16.00

-- (g) Schedule: daily at 00:10 for CURRENT_DATE
-- Uses pg_cron. If pg_cron is not installed on this server, this block prints a notice with the
-- exact job instead of failing.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_overdue_daily', '10 0 * * *',
      $cmd$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron is not installed on this server. Job to schedule: cron.schedule(%, %, %)',
      'refresh_overdue_daily', '10 0 * * *', $cmd$CALL q3_library.pr_refresh_overdue(CURRENT_DATE)$cmd$;
  END IF;
END $do$;

-- Where pg_cron is installed, inspect the job and its run history with:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC;
