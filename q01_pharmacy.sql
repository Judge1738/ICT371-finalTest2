-- ICT371 Advanced Database
-- Question 1: Pharmacy Stock and Daily Sales (PostgreSQL)

DROP SCHEMA IF EXISTS q1_pharmacy CASCADE;
CREATE SCHEMA q1_pharmacy;
SET search_path = q1_pharmacy;

-- (a) Tables and seed medicines
CREATE TABLE medicines (
  medicine_id   SERIAL PRIMARY KEY,
  medicine_name VARCHAR(100) NOT NULL,
  unit_price    NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  stock_qty     INT NOT NULL CHECK (stock_qty >= 0)
);

CREATE TABLE sales (
  sale_id     SERIAL PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  quantity    INT NOT NULL CHECK (quantity > 0),
  unit_price  NUMERIC(10,2) NOT NULL CHECK (unit_price > 0),
  sold_on     DATE NOT NULL
);

CREATE TABLE stock_audit (
  audit_id    SERIAL PRIMARY KEY,
  medicine_id INT NOT NULL REFERENCES medicines(medicine_id),
  old_qty     INT NOT NULL,
  new_qty     INT NOT NULL,
  changed_at  TIMESTAMP NOT NULL DEFAULT now()
);

CREATE TABLE daily_sales (
  sales_date   DATE PRIMARY KEY,
  total_qty    INT NOT NULL,
  total_amount NUMERIC(12,2) NOT NULL
);

INSERT INTO medicines (medicine_name, unit_price, stock_qty) VALUES
('Paracetamol', 2.50, 50),
('Amoxicillin', 8.00, 30),
('Ibuprofen',   4.00, 12);

-- (b) Function
CREATE OR REPLACE FUNCTION fn_sale_value(p_medicine_id INT, p_quantity INT)
RETURNS NUMERIC AS $$
DECLARE v_price NUMERIC;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  SELECT unit_price INTO v_price FROM medicines WHERE medicine_id = p_medicine_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  RETURN v_price * p_quantity;
END; $$ LANGUAGE plpgsql;

-- (c) Procedure
CREATE OR REPLACE PROCEDURE pr_record_sale(p_medicine_id INT, p_quantity INT, p_sold_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_price NUMERIC; v_stock INT;
BEGIN
  IF p_quantity IS NULL OR p_quantity <= 0 THEN
    RAISE EXCEPTION 'Invalid quantity: %', p_quantity;
  END IF;
  IF p_sold_on IS NULL THEN
    RAISE EXCEPTION 'Sale date is required';
  END IF;
  SELECT unit_price, stock_qty INTO v_price, v_stock
  FROM medicines WHERE medicine_id = p_medicine_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown medicine: %', p_medicine_id;
  END IF;
  IF v_stock < p_quantity THEN
    RAISE EXCEPTION 'Insufficient stock: % available, % requested', v_stock, p_quantity;
  END IF;
  INSERT INTO sales (medicine_id, quantity, unit_price, sold_on)
  VALUES (p_medicine_id, p_quantity, v_price, p_sold_on);
  UPDATE medicines SET stock_qty = stock_qty - p_quantity
  WHERE medicine_id = p_medicine_id;
END; $$;

-- (d) Trigger
CREATE OR REPLACE FUNCTION trg_stock_audit_fn() RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO stock_audit (medicine_id, old_qty, new_qty)
  VALUES (OLD.medicine_id, OLD.stock_qty, NEW.stock_qty);
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_stock_audit
AFTER UPDATE ON medicines
FOR EACH ROW
WHEN (OLD.stock_qty IS DISTINCT FROM NEW.stock_qty)
EXECUTE FUNCTION trg_stock_audit_fn();

-- (a) Six valid sales loaded through the procedure
CALL pr_record_sale(1, 10, CURRENT_DATE - 2);
CALL pr_record_sale(1, 5,  CURRENT_DATE - 2);
CALL pr_record_sale(2, 8,  CURRENT_DATE - 1);
CALL pr_record_sale(3, 4,  CURRENT_DATE - 1);
CALL pr_record_sale(1, 20, CURRENT_DATE);
CALL pr_record_sale(2, 15, CURRENT_DATE);

-- (e) View
CREATE VIEW v_low_stock AS
SELECT medicine_id, medicine_name, unit_price, stock_qty AS remaining_stock
FROM medicines
WHERE stock_qty < 10;

-- (f) Index: equality on medicine_id first, then range on sold_on
CREATE INDEX idx_sales_medicine_date ON sales (medicine_id, sold_on);

-- (g) Refresh procedure (idempotent upsert)
CREATE OR REPLACE PROCEDURE pr_refresh_sales(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO daily_sales (sales_date, total_qty, total_amount)
  SELECT p_day, COALESCE(SUM(quantity),0), COALESCE(SUM(quantity * unit_price),0)
  FROM sales WHERE sold_on = p_day
  ON CONFLICT (sales_date) DO UPDATE
  SET total_qty = EXCLUDED.total_qty,
      total_amount = EXCLUDED.total_amount;
END; $$;

-- ===== Tests =====
SELECT fn_sale_value(1, 4);              -- 10.00
-- SELECT fn_sale_value(99, 4);          -- error: unknown medicine
-- SELECT fn_sale_value(1, 0);           -- error: invalid quantity
-- CALL pr_record_sale(1, 999, CURRENT_DATE);  -- error: insufficient stock, tables unchanged

SELECT * FROM medicines ORDER BY medicine_id;
SELECT * FROM sales;
SELECT * FROM stock_audit;
SELECT * FROM v_low_stock;

SET enable_seqscan = off;
EXPLAIN SELECT * FROM sales
WHERE medicine_id = 1 AND sold_on BETWEEN CURRENT_DATE - 3 AND CURRENT_DATE;

CALL pr_refresh_sales(CURRENT_DATE);
CALL pr_refresh_sales(CURRENT_DATE);     -- rerun: no duplicate
SELECT * FROM daily_sales;

-- (g) Schedule: daily at 00:15 for the previous day
-- Uses pg_cron. If pg_cron is not installed on this server, this block prints a notice with the
-- exact job instead of failing.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_sales_daily', '15 0 * * *',
      $cmd$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron is not installed on this server. Job to schedule: cron.schedule(%, %, %)',
      'refresh_sales_daily', '15 0 * * *', $cmd$CALL q1_pharmacy.pr_refresh_sales(CURRENT_DATE - 1)$cmd$;
  END IF;
END $do$;

-- Where pg_cron is installed, inspect the job and its run history with:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC;
