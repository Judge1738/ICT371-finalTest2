-- ICT371 Advanced Database
-- Question 8: Transport Fleet Maintenance (PostgreSQL)
-- Service alert rule: vehicle has travelled at least 5,000 km since its last service.

DROP SCHEMA IF EXISTS q8_fleet CASCADE;
CREATE SCHEMA q8_fleet;
SET search_path = q8_fleet;

-- (a) Tables
CREATE TABLE vehicles (
  vehicle_id            SERIAL PRIMARY KEY,
  registration          VARCHAR(20) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
  trip_id        SERIAL PRIMARY KEY,
  vehicle_id     INT  NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT  NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT  NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT  NOT NULL,
  flagged_on       DATE NOT NULL
);

-- (a) Three vehicles with different service positions
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
('ZM 1001', 20000, 18000),   -- 2,000 km since service
('ZM 2002', 33000, 28500),   -- 4,500 km since service (becomes due after its trips)
('ZM 3003', 45000, 39000);   -- 6,000 km since service (already due)

-- (b) Function: 5,000 km rule
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
  v_current INT;
  v_service INT;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_current, v_service
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  RETURN (v_current - v_service) >= 5000;
END; $$ LANGUAGE plpgsql;

-- (d) Trigger: verify start odometer, reject invalid mileage, update odometer exactly once
CREATE OR REPLACE FUNCTION trg_trip_odometer_fn() RETURNS TRIGGER AS $$
DECLARE
  v_current INT;
BEGIN
  IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL THEN
    RAISE EXCEPTION 'Start and end odometer readings are required';
  END IF;
  IF NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: end odometer % must be greater than start odometer %',
      NEW.end_odometer, NEW.start_odometer;
  END IF;

  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
  END IF;
  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Start odometer % does not match current odometer % for vehicle %',
      NEW.start_odometer, v_current, NEW.vehicle_id;
  END IF;

  -- one UPDATE per inserted trip row
  UPDATE vehicles SET current_odometer = NEW.end_odometer
  WHERE vehicle_id = NEW.vehicle_id;

  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_trip_odometer_fn();

-- (c) Procedure: validate and insert the trip (the trigger updates the odometer)
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date, start and end odometer are required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM vehicles WHERE vehicle_id = p_vehicle_id) THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;
  IF p_end <= p_start THEN
    RAISE EXCEPTION 'End odometer % must be greater than start odometer %', p_end, p_start;
  END IF;
  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
  -- the vehicle odometer is NOT updated here
END; $$;

-- (a) Six trips, added through the procedure after the trigger is installed
CALL pr_record_trip(1, CURRENT_DATE - 12, 20000, 20800);
CALL pr_record_trip(1, CURRENT_DATE - 6,  20800, 21500);
CALL pr_record_trip(2, CURRENT_DATE - 10, 33000, 33400);
CALL pr_record_trip(2, CURRENT_DATE - 4,  33400, 34000);
CALL pr_record_trip(3, CURRENT_DATE - 8,  45000, 45600);
CALL pr_record_trip(3, CURRENT_DATE - 2,  45600, 46100);

-- (e) View: vehicles that currently meet the service threshold
CREATE VIEW v_service_due AS
SELECT registration,
       current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE fn_service_due(vehicle_id);

-- (f) Index: one vehicle's trips within a date range
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);
-- Justification: the query filters by vehicle_id (equality) and trip_on (range). With vehicle_id
-- first, the index jumps to one vehicle's entries; trip_on second keeps them in date order, so
-- the date range is a single contiguous slice of the index.

-- (g) Refresh procedure: insert/update an alert for each due vehicle, remove cleared ones
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
LANGUAGE plpgsql AS $$
BEGIN
  -- insert a new alert, or update the kilometres on an existing one (flagged_on keeps the first date)
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE fn_service_due(vehicle_id)
  ON CONFLICT (vehicle_id) DO UPDATE
  SET km_since_service = EXCLUDED.km_since_service;

  -- remove alerts for vehicles that are no longer due (serviced)
  DELETE FROM service_alerts
  WHERE NOT fn_service_due(vehicle_id);
END; $$;

-- ===== Tests =====
SELECT * FROM vehicles ORDER BY vehicle_id;   -- odometers moved by the trigger: 21500, 34000, 46100
SELECT * FROM trips ORDER BY trip_id;         -- 6 rows

SELECT fn_service_due(1);   -- false (3,500 km)
SELECT fn_service_due(2);   -- true  (5,500 km)
SELECT fn_service_due(3);   -- true  (7,100 km)
-- SELECT fn_service_due(99);                 -- error: unknown vehicle

SELECT * FROM v_service_due;                  -- ZM 2002 and ZM 3003

-- Procedure rejections (run one at a time; each should fail)
-- CALL pr_record_trip(99, CURRENT_DATE, 100, 200);        -- unknown vehicle
-- CALL pr_record_trip(1, CURRENT_DATE, 21500, 21500);     -- end not greater than start

-- Trigger rejections (each should fail; vehicle odometer must stay unchanged)
-- CALL pr_record_trip(1, CURRENT_DATE, 20000, 20500);     -- start does not match current 21500
-- INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
--   VALUES (1, CURRENT_DATE, 21500, 21000);               -- direct SQL with invalid mileage

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN CURRENT_DATE - 30 AND CURRENT_DATE;
RESET enable_seqscan;

CALL pr_refresh_service_alerts();
CALL pr_refresh_service_alerts();             -- rerun: still one alert per due vehicle
SELECT * FROM service_alerts ORDER BY vehicle_id;   -- vehicles 2 and 3

-- Service vehicle 3: its alert is removed on the next refresh
UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 3;
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts ORDER BY vehicle_id;   -- only vehicle 2 remains

-- (g) Schedule: every Monday at 06:00
-- Uses pg_cron. If pg_cron is not installed on this server, this block prints a notice with the
-- exact job instead of failing.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_service_alerts_weekly', '0 6 * * 1',
      $cmd$CALL q8_fleet.pr_refresh_service_alerts()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron is not installed on this server. Job to schedule: cron.schedule(%, %, %)',
      'refresh_service_alerts_weekly', '0 6 * * 1', $cmd$CALL q8_fleet.pr_refresh_service_alerts()$cmd$;
  END IF;
END $do$;

-- Where pg_cron is installed, inspect the job and its run history with:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC;
