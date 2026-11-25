-- ICT371 Advanced Database
-- Question 5: Hostel Room Allocation (PostgreSQL)
-- ACTIVE allocations occupy beds; ENDED allocations are history only.

DROP SCHEMA IF EXISTS q5_hostel CASCADE;
CREATE SCHEMA q5_hostel;
SET search_path = q5_hostel;

-- (a) Tables
CREATE TABLE students (
  student_id     SERIAL PRIMARY KEY,
  student_number VARCHAR(20) NOT NULL UNIQUE,
  full_name      VARCHAR(100) NOT NULL
);

CREATE TABLE rooms (
  room_id     SERIAL PRIMARY KEY,
  room_number VARCHAR(10) NOT NULL UNIQUE,
  capacity    INT NOT NULL CHECK (capacity > 0)
);

CREATE TABLE allocations (
  allocation_id SERIAL PRIMARY KEY,
  student_id    INT NOT NULL REFERENCES students(student_id),
  room_id       INT NOT NULL REFERENCES rooms(room_id),
  allocated_on  DATE NOT NULL,
  released_on   DATE NULL,
  status        VARCHAR(10) NOT NULL,
  CONSTRAINT chk_alloc_status CHECK (status IN ('ACTIVE','ENDED')),
  -- ACTIVE requires released_on NULL; ENDED requires a release date
  CONSTRAINT chk_alloc_release CHECK (
        (status = 'ACTIVE' AND released_on IS NULL)
     OR (status = 'ENDED'  AND released_on IS NOT NULL AND released_on >= allocated_on)
  )
);

CREATE TABLE occupancy_snapshot (
  snapshot_date DATE NOT NULL,
  room_id       INT  NOT NULL REFERENCES rooms(room_id),
  occupied_beds INT  NOT NULL,
  free_beds     INT  NOT NULL,
  PRIMARY KEY (snapshot_date, room_id)
);

-- (a) Rooms and students
INSERT INTO rooms (room_number, capacity) VALUES
('R101', 2),    -- will be full
('R102', 3),    -- will be partly occupied
('R103', 2);    -- will stay empty

INSERT INTO students (student_number, full_name) VALUES
('S001', 'Chileshe Mutale'),
('S002', 'Bwalya Simukonda'),
('S003', 'Tiwonge Phiri'),
('S004', 'Mutinta Hamusonde'),
('S005', 'Kelvin Zimba'),
('S006', 'Lubona Siame');

-- (b) Function: capacity minus ACTIVE allocations (ENDED rows are ignored)
CREATE OR REPLACE FUNCTION fn_free_beds(p_room_id INT)
RETURNS INT AS $$
DECLARE v_capacity INT;
BEGIN
  SELECT capacity INTO v_capacity FROM rooms WHERE room_id = p_room_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;
  RETURN v_capacity - (SELECT COUNT(*) FROM allocations
                       WHERE room_id = p_room_id AND status = 'ACTIVE');
END; $$ LANGUAGE plpgsql;

-- (d) Trigger: capacity and one-ACTIVE-per-student for direct SQL changes
CREATE OR REPLACE FUNCTION trg_allocation_rules_fn() RETURNS TRIGGER AS $$
DECLARE
  v_exclude  INT := NULL;
  v_capacity INT;
  v_count    INT;
BEGIN
  IF NEW.status = 'ACTIVE' THEN
    -- on UPDATE, exclude the row being updated when counting other allocations
    IF TG_OP = 'UPDATE' THEN
      v_exclude := OLD.allocation_id;
    END IF;

    -- one ACTIVE allocation per student
    IF EXISTS (SELECT 1 FROM allocations
               WHERE student_id = NEW.student_id
                 AND status = 'ACTIVE'
                 AND allocation_id IS DISTINCT FROM v_exclude) THEN
      RAISE EXCEPTION 'Student % already has an ACTIVE allocation', NEW.student_id;
    END IF;

    -- capacity (lock the room row so two allocations cannot take the last bed together)
    SELECT capacity INTO v_capacity FROM rooms WHERE room_id = NEW.room_id FOR UPDATE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'Unknown room: %', NEW.room_id;
    END IF;
    SELECT COUNT(*) INTO v_count FROM allocations
    WHERE room_id = NEW.room_id
      AND status = 'ACTIVE'
      AND allocation_id IS DISTINCT FROM v_exclude;
    IF v_count >= v_capacity THEN
      RAISE EXCEPTION 'Room % is full (capacity %)', NEW.room_id, v_capacity;
    END IF;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_allocation_rules
BEFORE INSERT OR UPDATE ON allocations
FOR EACH ROW
EXECUTE FUNCTION trg_allocation_rules_fn();

-- (c) Procedure: validate, then create one ACTIVE allocation
CREATE OR REPLACE PROCEDURE pr_allocate_room(p_student_id INT, p_room_id INT, p_allocated_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_dummy INT;
BEGIN
  IF p_allocated_on IS NULL THEN
    RAISE EXCEPTION 'Allocation date is required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM students WHERE student_id = p_student_id) THEN
    RAISE EXCEPTION 'Unknown student: %', p_student_id;
  END IF;
  -- lock the room row, then check availability
  SELECT room_id INTO v_dummy FROM rooms WHERE room_id = p_room_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown room: %', p_room_id;
  END IF;
  IF EXISTS (SELECT 1 FROM allocations
             WHERE student_id = p_student_id AND status = 'ACTIVE') THEN
    RAISE EXCEPTION 'Student % already has an ACTIVE allocation', p_student_id;
  END IF;
  IF fn_free_beds(p_room_id) <= 0 THEN
    RAISE EXCEPTION 'Room % has no free beds', p_room_id;
  END IF;
  INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status)
  VALUES (p_student_id, p_room_id, p_allocated_on, NULL, 'ACTIVE');
END; $$;

-- (a) Allocations: ACTIVE ones through the procedure
CALL pr_allocate_room(1, 1, CURRENT_DATE - 30);   -- R101 full (2 of 2)
CALL pr_allocate_room(2, 1, CURRENT_DATE - 20);
CALL pr_allocate_room(3, 2, CURRENT_DATE - 15);   -- R102 partly occupied (2 of 3)
CALL pr_allocate_room(4, 2, CURRENT_DATE - 10);
-- ENDED history (does not occupy beds); R103 stays empty
INSERT INTO allocations (student_id, room_id, allocated_on, released_on, status) VALUES
(5, 3, CURRENT_DATE - 90,  CURRENT_DATE - 45, 'ENDED'),
(1, 2, CURRENT_DATE - 100, CURRENT_DATE - 40, 'ENDED');

-- (e) View: every room, including rooms with no allocations
CREATE VIEW v_room_occupancy AS
SELECT r.room_id,
       r.room_number,
       r.capacity,
       COUNT(a.allocation_id)              AS occupied_beds,
       r.capacity - COUNT(a.allocation_id) AS free_beds
FROM rooms r
LEFT JOIN allocations a
       ON a.room_id = r.room_id AND a.status = 'ACTIVE'
GROUP BY r.room_id, r.room_number, r.capacity;

-- (f) Partial index: only ACTIVE rows, keyed by room_id
CREATE INDEX idx_allocations_active_room ON allocations (room_id) WHERE status = 'ACTIVE';
-- Justification: capacity checks and occupancy counts always ask for the ACTIVE rows of one
-- room. The partial index holds only ACTIVE rows (ENDED history is left out), so it stays
-- small and room_id equality finds the rows directly.

-- (g) Refresh procedure: one row per date and room, replaced on rerun
CREATE OR REPLACE PROCEDURE pr_refresh_occupancy()
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO occupancy_snapshot (snapshot_date, room_id, occupied_beds, free_beds)
  SELECT CURRENT_DATE, room_id, occupied_beds, free_beds
  FROM v_room_occupancy
  ON CONFLICT (snapshot_date, room_id) DO UPDATE
  SET occupied_beds = EXCLUDED.occupied_beds,
      free_beds     = EXCLUDED.free_beds;
END; $$;

-- ===== Tests =====
SELECT * FROM rooms ORDER BY room_id;
SELECT * FROM students ORDER BY student_id;
SELECT * FROM allocations ORDER BY allocation_id;   -- 4 ACTIVE, 2 ENDED

SELECT fn_free_beds(1);   -- 0 (full)
SELECT fn_free_beds(2);   -- 1 (the ENDED row does not reduce availability)
SELECT fn_free_beds(3);   -- 2 (empty; the ENDED row does not count)
-- SELECT fn_free_beds(99);                          -- error: unknown room

SELECT * FROM v_room_occupancy ORDER BY room_id;    -- R101 2/0, R102 2/1, R103 0/2

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM allocations WHERE room_id = 1 AND status = 'ACTIVE';
RESET enable_seqscan;

CALL pr_refresh_occupancy();
CALL pr_refresh_occupancy();                        -- rerun: rows replaced, not duplicated
SELECT * FROM occupancy_snapshot ORDER BY room_id;  -- 3 rows for today

-- Updating a row in a full room works (the row being updated is excluded from the count)
UPDATE allocations SET allocated_on = allocated_on WHERE allocation_id = 1;

-- Procedure rejections (run one at a time; each should fail)
-- CALL pr_allocate_room(99, 3, CURRENT_DATE);       -- unknown student
-- CALL pr_allocate_room(6, 99, CURRENT_DATE);       -- unknown room
-- CALL pr_allocate_room(1, 3, CURRENT_DATE);        -- student 1 already ACTIVE
-- CALL pr_allocate_room(6, 1, CURRENT_DATE);        -- room R101 is full

-- Trigger rejections for direct SQL (each should fail)
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (6, 1, CURRENT_DATE, 'ACTIVE');          -- capacity exceeded
-- INSERT INTO allocations (student_id, room_id, allocated_on, status)
--   VALUES (1, 3, CURRENT_DATE, 'ACTIVE');          -- second ACTIVE allocation for student 1
-- UPDATE allocations SET room_id = 1 WHERE allocation_id = 3;   -- moving into a full room

-- A valid extra allocation (changes the occupancy counts above if you run it):
-- CALL pr_allocate_room(6, 3, CURRENT_DATE);

-- (g) Schedule: daily at 23:55
-- Uses pg_cron. If pg_cron is not installed on this server, this block prints a notice with the
-- exact job instead of failing.
DO $do$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'pg_cron') THEN
    CREATE EXTENSION IF NOT EXISTS pg_cron;
    PERFORM cron.schedule('refresh_occupancy_daily', '55 23 * * *',
      $cmd$CALL q5_hostel.pr_refresh_occupancy()$cmd$);
  ELSE
    RAISE NOTICE 'pg_cron is not installed on this server. Job to schedule: cron.schedule(%, %, %)',
      'refresh_occupancy_daily', '55 23 * * *', $cmd$CALL q5_hostel.pr_refresh_occupancy()$cmd$;
  END IF;
END $do$;

-- Where pg_cron is installed, inspect the job and its run history with:
-- SELECT jobid, jobname, schedule, command, active FROM cron.job;
-- SELECT jobid, status, return_message, start_time, end_time FROM cron.job_run_details ORDER BY start_time DESC;
