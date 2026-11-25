---Q7
--a
CREATE TABLE customers (
customer_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
full_name TEXT NOT NULL
);
CREATE TABLE readings (
reading_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
customer_id BIGINT NOT NULL REFERENCES customers(customer_id),
reading_month DATE NOT NULL CHECK (EXTRACT(DAY FROM reading_month) = 1),
previous_reading NUMERIC(12,2) NOT NULL CHECK (previous_reading >= 0),
current_reading NUMERIC(12,2) NOT NULL CHECK (current_reading >= 0),
UNIQUE (customer_id, reading_month)
);
CREATE TABLE bills (
bill_id BIGINT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
reading_id BIGINT NOT NULL UNIQUE REFERENCES readings(reading_id),
charge NUMERIC(12,2) NOT NULL CHECK (charge >= 0),
amount_paid NUMERIC(12,2) NOT NULL DEFAULT 0
CHECK (amount_paid >= 0 AND amount_paid <= charge),
due_on DATE NOT NULL
);
CREATE TABLE receivable_snapshot (
snapshot_date DATE PRIMARY KEY,
total_due NUMERIC(14,2) NOT NULL
);

--b
CREATE OR REPLACE FUNCTION fn_water_charge(p_units NUMERIC)
RETURNS NUMERIC(12,2) LANGUAGE plpgsql AS $$
BEGIN
IF p_units IS NULL OR p_units < 0 THEN
RAISE EXCEPTION 'Consumption must be non-negative and not NULL';
END IF;
-- K5 for each of the first 10 units, K8 for every unit above 10.
RETURN (LEAST(p_units, 10) * 5 + GREATEST(p_units - 10, 0) * 8)::NUMERIC(12,2);
END; $$;

--c
CREATE OR REPLACE PROCEDURE pr_generate_bill(p_reading_id BIGINT, p_due_on DATE)
LANGUAGE plpgsql AS $$
DECLARE v_previous NUMERIC(12,2); v_current NUMERIC(12,2); v_charge NUMERIC(12,2);
BEGIN
IF p_due_on IS NULL THEN
RAISE EXCEPTION 'Due date is required';
END IF;
SELECT previous_reading, current_reading INTO v_previous, v_current
FROM readings WHERE reading_id = p_reading_id;
IF NOT FOUND THEN
RAISE EXCEPTION 'Unknown reading ID %', p_reading_id;
END IF;
IF EXISTS (SELECT 1 FROM bills WHERE reading_id = p_reading_id) THEN
RAISE EXCEPTION 'A bill already exists for reading %', p_reading_id;
END IF;
v_charge := fn_water_charge(v_current - v_previous);
INSERT INTO bills(reading_id, charge, amount_paid, due_on)
VALUES (p_reading_id, v_charge, 0, p_due_on);
END; $$;


--d
CREATE OR REPLACE FUNCTION trg_validate_reading()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
IF NEW.current_reading < NEW.previous_reading THEN
RAISE EXCEPTION 'Current meter reading cannot be below previous reading';
END IF;
RETURN NEW; -- a rejected row raises an exception and is never stored
END; $$;
CREATE TRIGGER readings_validate
BEFORE INSERT OR UPDATE ON readings FOR EACH ROW
EXECUTE FUNCTION trg_validate_reading();

--e
CREATE OR REPLACE VIEW v_overdue_bills AS
SELECT c.full_name, b.due_on, b.charge - b.amount_paid AS outstanding_amount
FROM bills b
JOIN readings r ON r.reading_id = b.reading_id
JOIN customers c ON c.customer_id = r.customer_id
WHERE b.due_on < CURRENT_DATE AND b.amount_paid < b.charge;

--f
CREATE INDEX idx_bills_due_unpaid ON bills(due_on)
WHERE amount_paid < charge;
-- Matching query and plan (it repeats the index predicate amount_paid < charge):
EXPLAIN SELECT bill_id, reading_id, charge - amount_paid AS outstanding
FROM bills
WHERE due_on < CURRENT_DATE AND amount_paid < charge;

--g
CREATE OR REPLACE PROCEDURE pr_refresh_receivables()
LANGUAGE plpgsql AS $$
BEGIN
INSERT INTO receivable_snapshot(snapshot_date, total_due)
SELECT CURRENT_DATE, COALESCE(SUM(charge - amount_paid), 0)
FROM bills
WHERE amount_paid < charge
ON CONFLICT (snapshot_date) DO UPDATE
SET total_due = EXCLUDED.total_due;
END; $$;
-- Schedule: every day at 00:30.
CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('daily-water-receivables', '30 0 * * *',
$$CALL pr_refresh_receivables()$$);

---seeds
INSERT INTO customers(full_name) VALUES ('Mary'), ('James'), ('Lydia');
-- Consumption: 0, 10, 15, 7, 10, 0 units (zero, exactly 10 and above 10 are all covered).
INSERT INTO readings(customer_id, reading_month, previous_reading, current_reading) VALUES
(1, DATE '2026-09-01', 0, 0), (1, DATE '2026-10-01', 0, 10),
(2, DATE '2026-09-01', 10, 25), (2, DATE '2026-10-01', 25, 32),
(3, DATE '2026-09-01', 4, 14), (3, DATE '2026-10-01', 14, 14);
SELECT fn_water_charge(0) AS c0, fn_water_charge(10) AS c10, fn_water_charge(15) AS c15;
-- 0.00, 50.00, 90.00
-- Some bills are already past due, others are not due yet.
CALL pr_generate_bill(1, CURRENT_DATE - 20); -- K0
CALL pr_generate_bill(2, CURRENT_DATE + 14); -- K50, not yet due
CALL pr_generate_bill(3, CURRENT_DATE - 20); -- K90
CALL pr_generate_bill(4, CURRENT_DATE - 5); -- K35
CALL pr_generate_bill(5, CURRENT_DATE - 20); -- K50
CALL pr_generate_bill(6, CURRENT_DATE + 14); -- K0
UPDATE bills SET amount_paid = 50 WHERE bill_id = 5; -- fully paid
UPDATE bills SET amount_paid = 30 WHERE bill_id = 3; -- partly paid (K60 left)
SELECT * FROM v_overdue_bills ORDER BY due_on, full_name; -- bills 3 (K60) and 4 (K35)
CALL pr_refresh_receivables();
CALL pr_refresh_receivables(); -- rerun replaces today's row
SELECT * FROM receivable_snapshot; -- 145.00 = 50 + 60 + 35 (all unpaid bills)

