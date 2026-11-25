-- ICT371 Advanced Database
-- Question 4: Clinic Appointment Scheduling (PostgreSQL)
-- Slots per doctor per day: 09:00, 10:00, 11:00, 12:00

DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path = q4_clinic;

-- (a) Tables
CREATE TABLE patients (
  patient_id SERIAL PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
  doctor_id  SERIAL PRIMARY KEY,
  full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
  appointment_id  SERIAL PRIMARY KEY,
  patient_id      INT  NOT NULL REFERENCES patients(patient_id),
  doctor_id       INT  NOT NULL REFERENCES doctors(doctor_id),
  appointment_day DATE NOT NULL,
  slot_time       TIME NOT NULL,
  status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
  CONSTRAINT chk_slot   CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
  CONSTRAINT chk_status CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

CREATE TABLE clinic_summary (
  summary_date    DATE PRIMARY KEY,
  booked_count    INT NOT NULL,
  attended_count  INT NOT NULL,
  cancelled_count INT NOT NULL
);

INSERT INTO patients (full_name) VALUES
('Esther Mulenga'), ('Joseph Sakala'), ('Natasha Kunda');

INSERT INTO doctors (full_name) VALUES
('Dr. Mwale'), ('Dr. Zulu'), ('Dr. Tembo');

-- (b) Function: non-cancelled appointments for a doctor on a day
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT AS $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  -- COUNT returns 0 when the day has no bookings
  RETURN (SELECT COUNT(*) FROM appointments
          WHERE doctor_id = p_doctor_id
            AND appointment_day = p_day
            AND status <> 'CANCELLED');
END; $$ LANGUAGE plpgsql;

-- (d) Trigger: reject a clash with another non-cancelled appointment
CREATE OR REPLACE FUNCTION trg_appointment_clash_fn() RETURNS TRIGGER AS $$
DECLARE
  v_exclude INT := NULL;
BEGIN
  IF NEW.status <> 'CANCELLED' THEN
    -- on UPDATE, leave out the appointment being changed
    IF TG_OP = 'UPDATE' THEN
      v_exclude := OLD.appointment_id;
    END IF;
    IF EXISTS (
      SELECT 1 FROM appointments
      WHERE doctor_id = NEW.doctor_id
        AND appointment_day = NEW.appointment_day
        AND slot_time = NEW.slot_time
        AND status <> 'CANCELLED'
        AND appointment_id IS DISTINCT FROM v_exclude
    ) THEN
      RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
        NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
    END IF;
  END IF;
  RETURN NEW;
END; $$ LANGUAGE plpgsql;

CREATE TRIGGER trg_appointment_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_appointment_clash_fn();

-- (c) Procedure: validate, then insert a BOOKED appointment
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
  IF p_day IS NULL OR p_slot IS NULL THEN
    RAISE EXCEPTION 'Day and slot are required';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
    RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
    RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
  END IF;
  IF p_day < CURRENT_DATE THEN
    RAISE EXCEPTION 'Cannot book a past date: %', p_day;
  END IF;
  IF p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
    RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
  END IF;
  -- the trigger rejects a clash with another non-cancelled appointment
  INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
  VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END; $$;

-- (a) Six seed appointments (trigger is already active, so none can clash).
--     The cancelled one shares doctor/day/slot with a booked one: allowed, it is cancelled.
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
(1, 1, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
(2, 1, CURRENT_DATE - 1, '10:00', 'ATTENDED'),
(1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
(2, 2, CURRENT_DATE,     '10:00', 'BOOKED'),
(3, 1, CURRENT_DATE,     '11:00', 'BOOKED'),
(3, 1, CURRENT_DATE,     '09:00', 'CANCELLED');

-- (e) View: today's BOOKED appointments, names and slot only
CREATE VIEW v_today_appointments AS
SELECT a.appointment_id,
       p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE
  AND a.status = 'BOOKED'
ORDER BY a.slot_time;

-- (f) Non-unique composite index
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
-- Justification: the search filters on appointment_day and doctor_id together, so one index
-- on both columns finds the matching rows directly. It is non-unique because a doctor has
-- several appointments per day, and it also serves searches by appointment_day alone.

-- (g) Refresh procedure: count each status for the date (rerun replaces the row)
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
  INSERT INTO clinic_summary (summary_date, booked_count, attended_count, cancelled_count)
  SELECT p_day,
         COUNT(*) FILTER (WHERE status = 'BOOKED'),
         COUNT(*) FILTER (WHERE status = 'ATTENDED'),
         COUNT(*) FILTER (WHERE status = 'CANCELLED')
  FROM appointments
  WHERE appointment_day = p_day
  ON CONFLICT (summary_date) DO UPDATE
  SET booked_count    = EXCLUDED.booked_count,
      attended_count  = EXCLUDED.attended_count,
      cancelled_count = EXCLUDED.cancelled_count;
END; $$;

-- ===== Tests =====
SELECT * FROM patients ORDER BY patient_id;
SELECT * FROM doctors ORDER BY doctor_id;
SELECT * FROM appointments ORDER BY appointment_id;   -- 6 rows

SELECT fn_daily_load(1, CURRENT_DATE);        -- 2 (the cancelled one is not counted)
SELECT fn_daily_load(3, CURRENT_DATE);        -- 0 (no bookings)
-- SELECT fn_daily_load(99, CURRENT_DATE);    -- error: unknown doctor

-- Valid booking through the procedure (adds a 7th row for tomorrow)
CALL pr_book_appointment(3, 3, CURRENT_DATE + 1, '09:00');
SELECT * FROM appointments WHERE appointment_day = CURRENT_DATE + 1;

-- Procedure rejections (run one at a time; each should fail)
-- CALL pr_book_appointment(99, 1, CURRENT_DATE + 1, '10:00');   -- unknown patient
-- CALL pr_book_appointment(1, 99, CURRENT_DATE + 1, '10:00');   -- unknown doctor
-- CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '10:00');    -- past date
-- CALL pr_book_appointment(1, 1, CURRENT_DATE + 1, '13:00');    -- unsupported slot
-- CALL pr_book_appointment(2, 1, CURRENT_DATE, '09:00');        -- clash (trigger)

-- Trigger tests on UPDATE
UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 3;   -- allowed: excludes itself
-- UPDATE appointments SET slot_time = '11:00' WHERE appointment_id = 3;   -- clash with appointment 5
-- UPDATE appointments SET status = 'BOOKED' WHERE appointment_id = 6;     -- clash with appointment 3

SELECT * FROM v_today_appointments;           -- 3 booked appointments today, names only

SET enable_seqscan = off;   -- tables are tiny; this forces the planner to show the index
EXPLAIN SELECT * FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
RESET enable_seqscan;

CALL pr_refresh_clinic_summary(CURRENT_DATE);
CALL pr_refresh_clinic_summary(CURRENT_DATE);       -- rerun: row replaced
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
SELECT * FROM clinic_summary ORDER BY summary_date; -- yesterday: 0/2/0, today: 3/0/1

-- Schedule: daily at 01:00 for the previous day (requires pg_cron)
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('refresh_clinic_summary_daily', '0 1 * * *',
  $$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
SELECT jobid, schedule, command, jobname FROM cron.job;
