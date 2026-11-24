-- ICT371 Advanced Database | Question 4: Clinic Appointment Scheduling
-- PostgreSQL. Run the whole file in one go (psql -f, or the pgAdmin Query Tool).

DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path = q4_clinic, public;

------------------------------------------------------------------
-- (a) Database
------------------------------------------------------------------
CREATE TABLE patients (
    patient_id SERIAL PRIMARY KEY,
    full_name  VARCHAR(100) NOT NULL
);

CREATE TABLE doctors (
    doctor_id SERIAL PRIMARY KEY,
    full_name VARCHAR(100) NOT NULL
);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT  NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT  NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL,
    status          VARCHAR(10) NOT NULL DEFAULT 'BOOKED',
    CONSTRAINT ck_status CHECK (status IN ('BOOKED', 'ATTENDED', 'CANCELLED')),
    CONSTRAINT ck_slot   CHECK (slot_time IN (TIME '09:00', TIME '10:00',
                                              TIME '11:00', TIME '12:00'))
);

-- Hard guarantee against races between two sessions: the trigger below gives a
-- friendly error first, and this partial unique index is the final safety net.
CREATE UNIQUE INDEX uq_active_slot
    ON appointments (doctor_id, appointment_day, slot_time)
    WHERE status <> 'CANCELLED';

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL,
    attended_count  INT NOT NULL,
    cancelled_count INT NOT NULL
);

------------------------------------------------------------------
-- (b) Function: fn_daily_load
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE)
RETURNS INT
LANGUAGE plpgsql
SET search_path = q4_clinic, public
AS $$
DECLARE
    v_count INT;
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;

    -- COUNT(*) returns 0 when the day has no bookings
    SELECT COUNT(*) INTO v_count
      FROM appointments
     WHERE doctor_id = p_doctor_id
       AND appointment_day = p_day
       AND status <> 'CANCELLED';

    RETURN v_count;
END;
$$;

------------------------------------------------------------------
-- (c) Procedure: pr_book_appointment
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT,
                                                p_day DATE, p_slot TIME)
LANGUAGE plpgsql
SET search_path = q4_clinic, public
AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient: %', p_patient_id;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor: %', p_doctor_id;
    END IF;
    IF p_day IS NULL OR p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Appointment date % is in the past or missing', p_day;
    END IF;
    IF p_slot IS NULL OR p_slot NOT IN (TIME '09:00', TIME '10:00', TIME '11:00', TIME '12:00') THEN
        RAISE EXCEPTION 'Unsupported slot: % (use 09:00, 10:00, 11:00 or 12:00)', p_slot;
    END IF;

    -- The clash trigger rejects a double booking
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

------------------------------------------------------------------
-- (d) Trigger: reject a clash with another non-cancelled appointment
------------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_check_clash()
RETURNS TRIGGER
LANGUAGE plpgsql
SET search_path = q4_clinic, public
AS $$
BEGIN
    -- A cancelled appointment occupies no slot, so it can never clash
    IF NEW.status <> 'CANCELLED' THEN
        IF EXISTS (
            SELECT 1
              FROM appointments a
             WHERE a.doctor_id       = NEW.doctor_id
               AND a.appointment_day = NEW.appointment_day
               AND a.slot_time       = NEW.slot_time
               AND a.status         <> 'CANCELLED'
               -- on UPDATE, exclude the appointment being changed
               AND (TG_OP = 'INSERT' OR a.appointment_id <> NEW.appointment_id)
        ) THEN
            RAISE EXCEPTION 'Clash: doctor % already has an appointment on % at %',
                            NEW.doctor_id, NEW.appointment_day, NEW.slot_time;
        END IF;
    END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_check_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW
EXECUTE FUNCTION trg_fn_check_clash();

------------------------------------------------------------------
-- (a, continued) Seed data
------------------------------------------------------------------
INSERT INTO patients (full_name) VALUES ('Agnes Phiri'), ('Brighton Tembo'), ('Catherine Moyo');
INSERT INTO doctors  (full_name) VALUES ('Dr. Banda'), ('Dr. Mulenga'), ('Dr. Sichone');

-- Past appointments (direct inserts, since the procedure rejects past dates)
INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
 (1, 1, CURRENT_DATE - 3, '09:00', 'ATTENDED'),
 (2, 1, CURRENT_DATE - 3, '10:00', 'CANCELLED');

-- Today and future appointments through the procedure
CALL pr_book_appointment(1, 1, CURRENT_DATE,     '09:00');
CALL pr_book_appointment(2, 2, CURRENT_DATE,     '10:00');
CALL pr_book_appointment(3, 3, CURRENT_DATE,     '11:00');
CALL pr_book_appointment(3, 1, CURRENT_DATE + 1, '09:00');

SELECT * FROM appointments ORDER BY appointment_id;

------------------------------------------------------------------
-- (e) View: v_today_appointments (no unrelated patient data)
------------------------------------------------------------------
CREATE OR REPLACE VIEW v_today_appointments AS
SELECT p.full_name AS patient_name,
       d.full_name AS doctor_name,
       a.slot_time
  FROM appointments a
  JOIN patients p ON p.patient_id = a.patient_id
  JOIN doctors  d ON d.doctor_id  = a.doctor_id
 WHERE a.appointment_day = CURRENT_DATE
   AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments ORDER BY slot_time;

------------------------------------------------------------------
-- (f) Index: appointments searched by day and doctor
------------------------------------------------------------------
-- Both columns are tested for equality in the usual lookup ("Dr X on day Y"),
-- so a two-column B-tree answers it directly. It is non-unique because a
-- doctor has up to four appointments a day.
CREATE INDEX idx_appointments_day_doctor ON appointments (appointment_day, doctor_id);
ANALYZE appointments;

SET enable_seqscan = off;
EXPLAIN
SELECT appointment_id, slot_time, status
  FROM appointments
 WHERE appointment_day = CURRENT_DATE
   AND doctor_id = 1;
RESET enable_seqscan;

------------------------------------------------------------------
-- (g) Scheduled job
------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql
SET search_path = q4_clinic, public
AS $$
BEGIN
    IF p_day IS NULL THEN
        RAISE EXCEPTION 'p_day is required';
    END IF;

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
END;
$$;

-- pg_cron: daily at 01:00 for the previous day.
--   CREATE EXTENSION IF NOT EXISTS pg_cron;   (one-off, superuser)
SELECT cron.schedule(
    'clinic-daily-summary',
    '0 1 * * *',
    $$CALL q4_clinic.pr_refresh_clinic_summary((CURRENT_DATE - 1))$$
);
SELECT jobid, jobname, schedule, command FROM cron.job;

------------------------------------------------------------------
-- Tests
------------------------------------------------------------------
CALL pr_refresh_clinic_summary(CURRENT_DATE - 3);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 3);   -- rerun replaces
CALL pr_refresh_clinic_summary(CURRENT_DATE);
SELECT * FROM clinic_summary ORDER BY summary_date;

SELECT fn_daily_load(1, CURRENT_DATE)      AS dr1_today,
       fn_daily_load(1, CURRENT_DATE + 30) AS dr1_empty_day_0;

DO $$ BEGIN PERFORM fn_daily_load(99, CURRENT_DATE);
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE, '09:00');        -- clash
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE - 1, '09:00');    -- past date
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(1, 1, CURRENT_DATE + 2, '13:00');    -- bad slot
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
DO $$ BEGIN CALL pr_book_appointment(99, 1, CURRENT_DATE + 2, '09:00');   -- unknown patient
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;

-- UPDATE path: moving appointment 3 onto a taken slot is rejected,
-- while updating a row without changing its slot is not treated as a clash
DO $$ BEGIN
    UPDATE appointments SET doctor_id = 1, slot_time = '09:00'
     WHERE appointment_id = 4;   -- appointment 4 is Dr. Mulenga today at 10:00; moving it onto Dr. Banda 09:00 clashes
EXCEPTION WHEN OTHERS THEN RAISE NOTICE 'Rejected as expected: %', SQLERRM; END $$;
UPDATE appointments SET status = 'ATTENDED' WHERE appointment_id = 4;   -- fine: self excluded
SELECT appointment_id, doctor_id, appointment_day, slot_time, status FROM appointments ORDER BY 1;
