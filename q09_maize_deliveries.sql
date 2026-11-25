-- ICT371 Advanced Database
-- Question 9: Farmer Cooperative Maize Deliveries (PostgreSQL)
-- Rates per kg: grade A = K5, grade B = K4, grade C = K3.

DROP SCHEMA IF EXISTS q9_maize CASCADE;
CREATE SCHEMA q9_maize;
SET search_path = q9_maize;

-- (a) Tables
CREATE TABLE farmers (
  farmer_id     SERIAL PRIMARY KEY,
  farmer_number VARCHAR(20) NOT NULL UNIQUE,
  full_name     VARCHAR(100) NOT NULL
);

CREATE TABLE deliveries (
  delivery_id  SERIAL PRIMARY KEY,
  farmer_id    INT NOT NULL REFERENCES farmers(farmer_id),
  grade        CHAR(1) NOT NULL CHECK (grade IN ('A','B','C')),
  weight_kg    NUMERIC(10,2) NOT NULL CHECK (weight_kg > 0),
  unit_rate    NUMERIC(10,2) NOT NULL,      -- supplied by the trigger
  total_value  NUMERIC(12,2) NOT NULL,      -- supplied by the trigger
  delivered_on DATE NOT NULL,
  is_paid      BOOLEAN NOT NULL DEFAULT FALSE
);

CREATE TABLE daily_purchases (
  purchase_date DATE PRIMARY KEY,
  total_weight  NUMERIC(12,2) NOT NULL,
  total_value   NUMERIC(14,2) NOT NULL
);

INSERT INTO farmers (farmer_number, full_name) VALUES
('F001', 'Mwape Kasonde'),
('F002', 'Lameck Phiri'),
('F003', 'Dorothy Banda');

-- (b) Function: rate for a grade
CREATE OR REPLACE FUNCTION fn_maize_rate(p_grade VARCHAR)
RETURNS NUMERIC AS $$
BEGIN
  IF p_grade IS NULL THEN
    RAISE EXCEPTION 'Grade cannot be NULL';
  END IF;
  CASE p_grade
    WHEN 'A' THEN RETURN 5.00;
    WHEN 'B' THEN RETURN 4.00;
    WHEN 'C' THEN RETURN 3.00;
    ELSE RAISE EXCEPTION 'Unsupported grade: % (use A, B or C)', p_grade;
  END CASE;
END; $$ LANGUAGE plpgsql;

-- (d) Trigger: one pricing rule for every insert/update, including direct SQL
CREATE OR REPLACE FUNCTION trg_delivery_pricing_fn() RETURNS TRIGGER AS $$
BEGIN
  IF NEW.weight_kg IS NULL OR NEW.weight_kg <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', NEW.weight_kg;
  END IF;
  NEW.unit_rate   := fn_maize_rate(NEW.grade);
  NEW.total_value := ROUND(NEW.weight_kg * NEW.unit_rate, 2);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_delivery_pricing
BEFORE INSERT OR UPDATE ON deliveries
FOR EACH ROW
EXECUTE FUNCTION trg_delivery_pricing_fn();

-- (c) Procedure: basic fields only, is_paid false; the trigger supplies unit_rate and total_value
CREATE OR REPLACE PROCEDURE pr_receive_delivery(p_farmer_id INT, p_grade VARCHAR, p_weight NUMERIC, p_date DATE)
LANGUAGE plpgsql AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM farmers WHERE farmer_id = p_farmer_id) THEN
    RAISE EXCEPTION 'Unknown farmer: %', p_farmer_id;
  END IF;
  IF p_grade IS NULL OR p_grade NOT IN ('A','B','C') THEN
    RAISE EXCEPTION 'Invalid grade: % (use A, B or C)', p_grade;
  END IF;
  IF p_weight IS NULL OR p_weight <= 0 THEN
    RAISE EXCEPTION 'Weight must be positive, got %', p_weight;
  END IF;
  IF p_date IS NULL THEN
    RAISE EXCEPTION 'Delivery date is required';
  END IF;
  INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid)
  VALUES (p_farmer_id, p_grade, p_weight, p_date, FALSE);
END; $$;

-- (a) Six deliveries (trigger installed): all grades, paid and unpaid
-- Direct SQL inserts (rate and value are filled in by the trigger)
INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on, is_paid) VALUES
(1, 'A', 100.00, CURRENT_DATE - 6, TRUE),
(2, 'C', 200.00, CURRENT_DATE - 5, TRUE),
(3, 'B', 120.00, CURRENT_DATE - 2, TRUE),
(3, 'C',  75.25, CURRENT_DATE - 1, TRUE);
-- Through the procedure (unpaid)
CALL pr_receive_delivery(1, 'B', 80.50, CURRENT_DATE - 5);
CALL pr_receive_delivery(2, 'A', 50.00, CURRENT_DATE - 3);

-- (e) View: unpaid value per farmer, zero for farmers with nothing unpaid
CREATE VIEW v_farmer_amount_due AS
SELECT f.farmer_number,
       f.full_name,
       COALESCE(SUM(d.total_value), 0.00) AS total_unpaid
FROM farmers f
LEFT JOIN deliveries d
       ON d.farmer_id = f.farmer_id AND d.is_paid = FALSE
GROUP BY f.farmer_id, f.farmer_number, f.full_name;

-- (f) Composite index: farmer first (equality), then delivery date (range)
CREATE INDEX idx_deliveries_farmer_date ON deliveries (farmer_id, delivered_on);
-- Justification: the query filters one farmer's deliveries between two dates. farmer_id first
-- finds that farmer's entries directly, and delivered_on second keeps them in date order, so the
-- date range is one contiguous slice of the index.

-- (g) Refresh procedure: store (not add to) the day's weight and value
CREATE OR REPLACE PROCEDURE pr_refresh_purchases(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_purchases (purchase_date, total_weight, total_value)
  SELECT p_day, COALESCE(SUM(weight_kg), 0), COALESCE(SUM(total_value), 0)
  FROM deliveries
  WHERE delivered_on = p_day
  ON CONFLICT (purchase_date) DO UPDATE
  SET total_weight = EXCLUDED.total_weight,
      total_value  = EXCLUDED.total_value;
END; $$;

-- ===== Tests =====
SELECT * FROM farmers ORDER BY farmer_id;
SELECT * FROM deliveries ORDER BY delivery_id;
-- expected values: 500.00, 600.00, 480.00, 225.75, 322.00, 250.00

SELECT fn_maize_rate('A');   -- 5.00
SELECT fn_maize_rate('B');   -- 4.00
SELECT fn_maize_rate('C');   -- 3.00
-- SELECT fn_maize_rate('D');                         -- error: unsupported grade
-- SELECT fn_maize_rate(NULL);                        -- error: NULL grade

-- Procedure rejections (run one at a time; each should fail)
-- CALL pr_receive_delivery(99, 'A', 10, CURRENT_DATE);   -- unknown farmer
-- CALL pr_receive_delivery(1, 'D', 10, CURRENT_DATE);    -- invalid grade
-- CALL pr_receive_delivery(1, 'A', 0, CURRENT_DATE);     -- non-positive weight

-- Trigger on direct SQL (each is checked by the same pricing rule)
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, unit_rate, total_value, delivered_on)
--   VALUES (1, 'A', 10, 99, 9999, CURRENT_DATE);         -- accepted, but stored as rate 5.00, value 50.00
-- INSERT INTO deliveries (farmer_id, grade, weight_kg, delivered_on)
--   VALUES (1, 'A', -5, CURRENT_DATE);                   -- error: non-positive weight
-- UPDATE deliveries SET grade = 'A' WHERE delivery_id = 2;   -- rate and value are recalculated

SELECT * FROM v_farmer_amount_due ORDER BY farmer_number;   -- F001 322.00, F002 250.00, F003 0.00

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM deliveries
WHERE farmer_id = 1 AND delivered_on BETWEEN CURRENT_DATE - 10 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_purchases(CURRENT_DATE - 5);
CALL pr_refresh_purchases(CURRENT_DATE - 5);        -- rerun: replaced, not added again
SELECT * FROM daily_purchases;                      -- weight 280.50, value 922.00

-- (g) Schedule: daily at 01:30 for the previous day
-- Uses pg_cron. If pg_cron is not installed on this server, this block prints a notice with the
-- exact job instead of failing.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_purchases_daily', '30 1 * * *',
      $cmd$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron is not installed on this server. Job to schedule: cron.schedule(%, %, %)',
      'refresh_purchases_daily', '30 1 * * *', $cmd$CALL q9_maize.pr_refresh_purchases(CURRENT_DATE - 1)$cmd$;
  END IF;
END $do$;

-- Where pg_cron is installed, inspect the job and its run history with:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC;
