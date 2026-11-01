-- =====================================================================
-- CAMPUS SPORTS BOOKING - BAZA DE DATE (LABORATOR 5, v2.1)
-- Echipa: 3BITS | SGBD: PostgreSQL 16
-- Rulare:  psql -U <user> -d campus_sports -v ON_ERROR_STOP=1 -f schema_campus_sports_v2.sql
--
-- Marcaje:  [NOU]  = adaugat fata de schema originala v1
--           [v2.1] = adaugat/schimbat pentru concordanta cu Swagger si prototipul Figma
-- ATENTIE: scriptul sterge si recreeaza tot (sectiunea 1) -> doar pe baze locale / de test.
--
-- Coduri de eroare (SQLSTATE) pentru backend - err.original.code in Sequelize:
--   SB400 regula de business incalcata   -> HTTP 400
--   SB403 actiune interzisa / QR invalid -> HTTP 403
--   SB404 resursa inexistenta (QR etc.)  -> HTTP 404
--   SB409 conflict (locuri, plata)       -> HTTP 409
--   23P01 suprapunere (EXCLUDE)          -> HTTP 409
--   23505 duplicat (email, matricol)     -> HTTP 400 / 409
-- =====================================================================

SET client_min_messages TO WARNING;
SET timezone TO 'Europe/Bucharest';

-- =====================================================================
-- 1. CURATARE (ordinea dependintelor)
-- =====================================================================
DROP VIEW  IF EXISTS v_booking_details;
DROP VIEW  IF EXISTS v_facility_catalog;
DROP TABLE IF EXISTS booking_equipment  CASCADE;
DROP TABLE IF EXISTS equipment          CASCADE;
DROP TABLE IF EXISTS qr_codes           CASCADE;
DROP TABLE IF EXISTS payments           CASCADE;
DROP TABLE IF EXISTS bookings           CASCADE;
DROP TABLE IF EXISTS tariffs            CASCADE;
DROP TABLE IF EXISTS sport_facilities   CASCADE;
DROP TABLE IF EXISTS campus_locations   CASCADE;
DROP TABLE IF EXISTS amateur_profiles   CASCADE;
DROP TABLE IF EXISTS professor_profiles CASCADE;
DROP TABLE IF EXISTS student_profiles   CASCADE;
DROP TABLE IF EXISTS users              CASCADE;
DROP TABLE IF EXISTS app_settings       CASCADE;

-- [v2.1] sterge functiile din versiunile anterioare (altfel raman supraincarcari cu alte semnaturi)
DO $$
DECLARE r RECORD;
BEGIN
    FOR r IN SELECT p.oid::regprocedure AS sig
               FROM pg_proc p
              WHERE p.pronamespace = 'public'::regnamespace
                AND p.proname = ANY (ARRAY[
                    'fn_booking_hours','fn_price_breakdown','fn_calculate_price','fn_ron_to_eur',
                    'trg_bookings_biu','trg_bookings_after_terminal','trg_bookings_release_equipment',
                    'trg_booking_equipment_bi','trg_profile_role_check',
                    'create_booking','start_payment','initiate_payment','complete_payment',
                    'fn_confirm_booking','confirm_free_booking','register_payment','cancel_booking',
                    'validate_qr','expire_stale_bookings','get_available_slots','claim_due_reminders',
                    'register_user'])
    LOOP
        EXECUTE 'DROP FUNCTION ' || r.sig || ' CASCADE';
    END LOOP;
END $$;

DROP TYPE IF EXISTS user_role_enum      CASCADE;
DROP TYPE IF EXISTS booking_status_enum CASCADE;
DROP TYPE IF EXISTS payment_status_enum CASCADE;
DROP TYPE IF EXISTS booking_mode_enum   CASCADE;

CREATE EXTENSION IF NOT EXISTS btree_gist;   -- [NOU] pentru EXCLUDE (facilitate/utilizator + interval)

-- =====================================================================
-- 2. ENUMERARI
-- =====================================================================
CREATE TYPE user_role_enum      AS ENUM ('STUDENT', 'PROFESSOR', 'AMATEUR', 'RECEPTIONIST', 'ADMIN');
CREATE TYPE booking_status_enum AS ENUM ('INITIATED', 'PENDING_PAYMENT', 'CONFIRMED',
                                         'CHECKED_IN', 'COMPLETED', 'CANCELLED', 'EXPIRED');
CREATE TYPE payment_status_enum AS ENUM ('PENDING', 'SUCCESS', 'FAILED', 'REFUNDED');
-- [v2.1] EXCLUSIVE = intreaga facilitate (teren); SHARED = pe locuri (bazin "6/10 locuri", sauna, fitness)
CREATE TYPE booking_mode_enum   AS ENUM ('EXCLUSIVE', 'SHARED');

-- =====================================================================
-- 3. SETARI GLOBALE
-- =====================================================================
-- [v2.1] ex. cursul fix EUR/RON folosit pentru afisarea "25 RON / 5 EUR" din Figma
CREATE TABLE app_settings (
    setting_key   VARCHAR(50)  PRIMARY KEY,
    setting_value VARCHAR(200) NOT NULL,
    description   VARCHAR(200)
);

-- =====================================================================
-- 4. UTILIZATORI SI PROFILURI
-- =====================================================================
CREATE TABLE users (
    user_id       SERIAL PRIMARY KEY,
    full_name     VARCHAR(120) NOT NULL,
    email         VARCHAR(150) NOT NULL,
    phone_number  VARCHAR(20),                      -- [v2.1] optional (ecranul "Creare cont" nu il cere)
    password_hash VARCHAR(255) NOT NULL,
    role_type     user_role_enum NOT NULL DEFAULT 'STUDENT',
    is_active     BOOLEAN NOT NULL DEFAULT TRUE,
    -- [v2.1] setarile din ecranul "Contul meu" (limba, moneda, mod intunecat, reminder)
    preferred_language      VARCHAR(2) NOT NULL DEFAULT 'ro' CHECK (preferred_language IN ('ro', 'en')),
    preferred_currency      VARCHAR(3) NOT NULL DEFAULT 'RON' CHECK (preferred_currency IN ('RON', 'EUR')),
    dark_mode               BOOLEAN NOT NULL DEFAULT FALSE,
    reminder_minutes_before INT DEFAULT 60
                            CHECK (reminder_minutes_before IS NULL OR reminder_minutes_before BETWEEN 15 AND 180),
    created_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT ck_users_email_format CHECK (email ~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$')
);
CREATE UNIQUE INDEX ux_users_email_lower ON users (lower(email));

-- [v2.1] campurile specifice rolului sunt OPTIONALE: formularul de inregistrare cere doar nume, email, parola
CREATE TABLE student_profiles (
    student_id      SERIAL PRIMARY KEY,
    user_id         INT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE CASCADE,
    matricol_number VARCHAR(40) UNIQUE,
    faculty         VARCHAR(150),
    study_year      INT CHECK (study_year BETWEEN 1 AND 6)
);

CREATE TABLE professor_profiles (
    prof_id        SERIAL PRIMARY KEY,
    user_id        INT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE CASCADE,
    department     VARCHAR(150),
    academic_title VARCHAR(80)
);

CREATE TABLE amateur_profiles (
    amateur_id   SERIAL PRIMARY KEY,
    user_id      INT NOT NULL UNIQUE REFERENCES users(user_id) ON DELETE CASCADE,
    cnp_hash     VARCHAR(64),     -- optional; daca il colectati: HMAC-SHA256 cu secret de server, nu SHA-256 simplu
    organization VARCHAR(150)
);

-- =====================================================================
-- 5. FACILITATI SI LOCALIZARE
-- =====================================================================
CREATE TABLE campus_locations (
    location_id     SERIAL PRIMARY KEY,
    zone_name       VARCHAR(100) NOT NULL,
    building_name   VARCHAR(100) NOT NULL,
    address         VARCHAR(200) NOT NULL,
    geo_coordinates VARCHAR(60),
    contact_phone   VARCHAR(20)          -- [v2.1] "Pentru detalii, sunati la ..." (Figma: Detalii facilitate / Harta)
);

CREATE TABLE sport_facilities (
    facility_id         SERIAL PRIMARY KEY,
    location_id         INT NOT NULL REFERENCES campus_locations(location_id) ON DELETE RESTRICT,
    name                VARCHAR(120) NOT NULL,
    -- [v2.1] aceleasi valori ca enum-ul din Swagger (filtrul ?sportType=...)
    sport_type          VARCHAR(60)  NOT NULL
                        CHECK (sport_type IN ('Fotbal', 'Tenis', 'Natație', 'Fitness', 'Saună')),
    -- [v2.1] chip-urile de filtrare din Figma: Toate / Înot / Relaxare / Sporturi
    category            VARCHAR(30)  NOT NULL CHECK (category IN ('Sporturi', 'Înot', 'Relaxare')),
    booking_mode        booking_mode_enum NOT NULL DEFAULT 'EXCLUSIVE',   -- [v2.1]
    capacity            INT NOT NULL DEFAULT 10 CHECK (capacity > 0),     -- EXCLUSIVE: nr. maxim participanti; SHARED: nr. locuri / slot
    base_price_per_hour DECIMAL(10,2) NOT NULL DEFAULT 0.00 CHECK (base_price_per_hour >= 0),  -- SHARED: pret / loc / ora
    slot_minutes        INT NOT NULL DEFAULT 60 CHECK (slot_minutes BETWEEN 15 AND 240),       -- [v2.1] bazin 60 min, sauna 30 min
    has_lighting        BOOLEAN NOT NULL DEFAULT TRUE,
    is_active           BOOLEAN NOT NULL DEFAULT TRUE,
    opens_at            TIME NOT NULL DEFAULT '08:00',
    closes_at           TIME NOT NULL DEFAULT '22:00',
    -- [v2.1] zilele de functionare (ISO: 1 = luni ... 7 = duminica); Figma: bazin "luni-vineri"
    open_days           SMALLINT[] NOT NULL DEFAULT ARRAY[1,2,3,4,5,6,7]::SMALLINT[],
    -- [v2.1] "Rezerva din timp si primesti o reducere"
    early_booking_days     INT,
    early_booking_discount DECIMAL(5,2),
    CONSTRAINT ck_facility_hours CHECK (closes_at > opens_at),
    CONSTRAINT ck_facility_open_days CHECK (open_days <@ ARRAY[1,2,3,4,5,6,7]::SMALLINT[] AND cardinality(open_days) > 0),
    CONSTRAINT ck_facility_early CHECK (
        (early_booking_days IS NULL AND early_booking_discount IS NULL) OR
        (early_booking_days > 0 AND early_booking_discount BETWEEN 0 AND 100))
);

CREATE TABLE tariffs (
    tariff_id        SERIAL PRIMARY KEY,
    role_type        user_role_enum NOT NULL UNIQUE,
    discount_percent DECIMAL(5,2) NOT NULL DEFAULT 0.00 CHECK (discount_percent BETWEEN 0 AND 100),
    is_free_access   BOOLEAN NOT NULL DEFAULT FALSE,
    description      VARCHAR(200) NOT NULL
);

-- =====================================================================
-- 6. REZERVARI, PLATI, QR
-- =====================================================================
CREATE TABLE bookings (
    booking_id      SERIAL PRIMARY KEY,
    user_id         INT NOT NULL REFERENCES users(user_id)                 ON DELETE RESTRICT,
    facility_id     INT NOT NULL REFERENCES sport_facilities(facility_id)  ON DELETE RESTRICT,
    tariff_id       INT NOT NULL REFERENCES tariffs(tariff_id)             ON DELETE RESTRICT,
    booking_date    DATE GENERATED ALWAYS AS (((start_time AT TIME ZONE 'Europe/Bucharest')::date)) STORED,
    start_time      TIMESTAMPTZ NOT NULL,
    end_time        TIMESTAMPTZ NOT NULL,
    seats           INT NOT NULL DEFAULT 1 CHECK (seats > 0),      -- [v2.1] locuri rezervate (facilitati SHARED)
    exclusive_slot  BOOLEAN NOT NULL DEFAULT FALSE,                -- [v2.1] setat de trigger din modul facilitatii
    -- [v2.1] detalierea din ecranul "Rezumat si plata": tarif, reducere, echipament, total
    base_amount      DECIMAL(10,2) NOT NULL DEFAULT 0.00 CHECK (base_amount >= 0),
    discount_amount  DECIMAL(10,2) NOT NULL DEFAULT 0.00 CHECK (discount_amount >= 0),
    equipment_amount DECIMAL(10,2) NOT NULL DEFAULT 0.00 CHECK (equipment_amount >= 0),
    total_amount     DECIMAL(10,2) NOT NULL DEFAULT 0.00 CHECK (total_amount >= 0),
    status          booking_status_enum NOT NULL DEFAULT 'INITIATED',
    hold_expires_at TIMESTAMPTZ,                  -- blocarea de 5 minute (INITIATED / PENDING_PAYMENT)
    cancelled_at    TIMESTAMPTZ,
    reminder_enabled BOOLEAN NOT NULL DEFAULT TRUE,   -- [v2.1] comutatorul "Reminder cu 1 ora inainte" din ecranul 07
    reminder_sent_at TIMESTAMPTZ,                     -- [v2.1] ca job-ul sa nu trimita de doua ori
    created_at      TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    CONSTRAINT check_valid_time_interval CHECK (end_time > start_time),
    CONSTRAINT ck_bookings_amounts CHECK (discount_amount <= base_amount
                                          AND total_amount = base_amount - discount_amount + equipment_amount),
    -- PROTECTIE DUBLA-REZERVARE pe facilitati EXCLUSIVE (terenuri)
    CONSTRAINT ex_bookings_no_overlap EXCLUDE USING gist (
        facility_id WITH =,
        tstzrange(start_time, end_time, '[)') WITH &&
    ) WHERE (exclusive_slot AND status NOT IN ('CANCELLED', 'EXPIRED')),
    -- [v2.1] un utilizator nu poate avea doua rezervari active suprapuse (ex. sauna + bazin in acelasi timp)
    CONSTRAINT ex_bookings_user_no_overlap EXCLUDE USING gist (
        user_id WITH =,
        tstzrange(start_time, end_time, '[)') WITH &&
    ) WHERE (status NOT IN ('CANCELLED', 'EXPIRED'))
);

CREATE TABLE payments (
    payment_id      SERIAL PRIMARY KEY,
    booking_id      INT NOT NULL REFERENCES bookings(booking_id) ON DELETE RESTRICT,
    amount          DECIMAL(10,2) NOT NULL CHECK (amount > 0),
    payment_method  VARCHAR(50)  NOT NULL DEFAULT 'CARD_ONLINE',
    transaction_ref VARCHAR(120) NOT NULL UNIQUE,     -- ex. id-ul PaymentIntent din Stripe
    payment_status  payment_status_enum NOT NULL DEFAULT 'PENDING',
    processed_at    TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE UNIQUE INDEX ux_payments_one_success ON payments (booking_id) WHERE payment_status = 'SUCCESS';

CREATE TABLE qr_codes (
    qr_id                      SERIAL PRIMARY KEY,
    booking_id                 INT NOT NULL UNIQUE REFERENCES bookings(booking_id) ON DELETE CASCADE,
    encrypted_payload          TEXT NOT NULL UNIQUE,
    generated_at               TIMESTAMPTZ NOT NULL DEFAULT CURRENT_TIMESTAMP,
    is_valid                   BOOLEAN NOT NULL DEFAULT TRUE,
    is_scanned                 BOOLEAN NOT NULL DEFAULT FALSE,
    scanned_at                 TIMESTAMPTZ,
    scanned_by_receptionist_id INT REFERENCES users(user_id) ON DELETE SET NULL,
    CONSTRAINT ck_qr_scan_consistent CHECK (is_scanned = (scanned_at IS NOT NULL))
);

-- =====================================================================
-- 7. ECHIPAMENTE
-- =====================================================================
CREATE TABLE equipment (
    equipment_id    SERIAL PRIMARY KEY,
    name            VARCHAR(100) NOT NULL,
    sport_category  VARCHAR(60)  NOT NULL,
    available_stock INT NOT NULL DEFAULT 0 CHECK (available_stock >= 0),
    hourly_fee      DECIMAL(8,2) NOT NULL DEFAULT 0.00 CHECK (hourly_fee >= 0)
);

CREATE TABLE booking_equipment (
    booking_equip_id SERIAL PRIMARY KEY,
    booking_id   INT NOT NULL REFERENCES bookings(booking_id)    ON DELETE CASCADE,
    equipment_id INT NOT NULL REFERENCES equipment(equipment_id) ON DELETE RESTRICT,
    quantity     INT NOT NULL DEFAULT 1 CHECK (quantity > 0),
    cost         DECIMAL(10,2) NOT NULL DEFAULT 0.00,   -- calculat de trigger
    UNIQUE (booking_id, equipment_id)
);

-- =====================================================================
-- 8. INDEXURI (cele doua EXCLUDE creeaza deja indexuri GiST)
-- =====================================================================
CREATE INDEX idx_bookings_user_id       ON bookings (user_id);
CREATE INDEX idx_bookings_facility_date ON bookings (facility_id, booking_date);
CREATE INDEX idx_bookings_hold          ON bookings (hold_expires_at)
    WHERE status IN ('INITIATED', 'PENDING_PAYMENT');
CREATE INDEX idx_bookings_reminder      ON bookings (start_time)
    WHERE status = 'CONFIRMED' AND reminder_enabled AND reminder_sent_at IS NULL;     -- [v2.1]
CREATE INDEX idx_payments_booking       ON payments (booking_id);
CREATE INDEX idx_booking_equipment_bk   ON booking_equipment (booking_id);

-- =====================================================================
-- 9. FUNCTII SI TRIGGERE
-- =====================================================================

-- 9.1 Utilitare ---------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_booking_hours(p_start TIMESTAMPTZ, p_end TIMESTAMPTZ)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
    SELECT EXTRACT(EPOCH FROM (p_end - p_start)) / 3600.0
$$;

-- [v2.1] conversie RON -> EUR cu cursul din app_settings (Figma: "25 RON / 5 EUR")
CREATE OR REPLACE FUNCTION fn_ron_to_eur(p_ron NUMERIC)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT round(p_ron / (SELECT setting_value::NUMERIC FROM app_settings WHERE setting_key = 'eur_ron_rate'), 2)
$$;

-- 9.2 Calcul pret detaliat (endpoint "Tarife & Calcul Reduceri" + ecranul "Rezumat si plata") [v2.1]
--   price_base      = pretul fara reduceri (ore * pret/ora * locuri, daca facilitatea e SHARED)
--   price_discount  = reducerea totala (rol + rezervare din timp, aplicate succesiv)
--   price_total     = de plata (fara echipament)
CREATE OR REPLACE FUNCTION fn_price_breakdown(p_user_id INT, p_facility_id INT,
                                              p_start TIMESTAMPTZ, p_end TIMESTAMPTZ,
                                              p_seats INT DEFAULT 1, p_now TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (price_base NUMERIC, price_discount NUMERIC, price_total NUMERIC,
               role_discount_pct NUMERIC, early_discount_pct NUMERIC)
LANGUAGE plpgsql STABLE AS $$
DECLARE
    v_t     tariffs%ROWTYPE;
    v_f     sport_facilities%ROWTYPE;
    v_base  NUMERIC;
    v_role  NUMERIC;
    v_early NUMERIC := 0;
    v_total NUMERIC;
BEGIN
    SELECT t.* INTO v_t
      FROM tariffs t JOIN users u ON u.role_type = t.role_type
     WHERE u.user_id = p_user_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Utilizatorul % nu are un tarif definit (rol fara drept de rezervare)', p_user_id
            USING ERRCODE = 'SB403';
    END IF;

    SELECT * INTO v_f FROM sport_facilities WHERE facility_id = p_facility_id;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Facilitatea % nu exista', p_facility_id USING ERRCODE = 'SB404';
    END IF;

    v_base := round(v_f.base_price_per_hour * fn_booking_hours(p_start, p_end)
                    * CASE WHEN v_f.booking_mode = 'SHARED' THEN GREATEST(p_seats, 1) ELSE 1 END, 2);
    v_role := CASE WHEN v_t.is_free_access THEN 100 ELSE v_t.discount_percent END;
    IF v_f.early_booking_days IS NOT NULL
       AND p_start - p_now >= make_interval(days => v_f.early_booking_days) THEN
        v_early := v_f.early_booking_discount;
    END IF;
    v_total := round(v_base * (1 - v_role / 100.0) * (1 - v_early / 100.0), 2);

    RETURN QUERY SELECT v_base, v_base - v_total, v_total, v_role, v_early;
END $$;

-- varianta scurta: doar totalul
CREATE OR REPLACE FUNCTION fn_calculate_price(p_user_id INT, p_facility_id INT,
                                              p_start TIMESTAMPTZ, p_end TIMESTAMPTZ,
                                              p_seats INT DEFAULT 1)
RETURNS NUMERIC LANGUAGE sql STABLE AS $$
    SELECT price_total FROM fn_price_breakdown(p_user_id, p_facility_id, p_start, p_end, p_seats)
$$;

-- 9.3 TRIGGER pe bookings: reguli de business + automat de stari -------------
CREATE OR REPLACE FUNCTION trg_bookings_biu() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_fac   sport_facilities%ROWTYPE;
    v_ls    TIMESTAMP;
    v_le    TIMESTAMP;
    v_taken INT;
BEGIN
    IF TG_OP = 'INSERT' THEN
        SELECT * INTO v_fac FROM sport_facilities WHERE facility_id = NEW.facility_id;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Facilitatea % nu exista', NEW.facility_id USING ERRCODE = 'SB404';
        END IF;
        IF NOT v_fac.is_active THEN
            RAISE EXCEPTION 'Facilitatea "%" este inactiva (mentenanta)', v_fac.name USING ERRCODE = 'SB400';
        END IF;

        v_ls := NEW.start_time AT TIME ZONE 'Europe/Bucharest';
        v_le := NEW.end_time   AT TIME ZONE 'Europe/Bucharest';
        IF v_ls::date <> v_le::date THEN
            RAISE EXCEPTION 'Rezervarea nu poate depasi miezul noptii' USING ERRCODE = 'SB400';
        END IF;
        IF NOT (EXTRACT(ISODOW FROM v_ls)::SMALLINT = ANY (v_fac.open_days)) THEN
            RAISE EXCEPTION 'Facilitatea nu functioneaza in aceasta zi' USING ERRCODE = 'SB400';
        END IF;
        IF v_ls::time < v_fac.opens_at OR v_le::time > v_fac.closes_at THEN
            RAISE EXCEPTION 'In afara programului facilitatii (%-%)', v_fac.opens_at, v_fac.closes_at
                USING ERRCODE = 'SB400';
        END IF;
        -- [v2.1] rezervarea trebuie sa respecte grila de sloturi (60 min bazin, 30 min sauna)
        IF MOD(EXTRACT(EPOCH FROM (v_ls::time - v_fac.opens_at)), v_fac.slot_minutes * 60) <> 0
           OR MOD(EXTRACT(EPOCH FROM (NEW.end_time - NEW.start_time)), v_fac.slot_minutes * 60) <> 0 THEN
            RAISE EXCEPTION 'Rezervarea trebuie sa respecte sloturile de % minute ale facilitatii', v_fac.slot_minutes
                USING ERRCODE = 'SB400';
        END IF;
        IF NEW.start_time <= now() THEN
            RAISE EXCEPTION 'Nu se pot face rezervari in trecut' USING ERRCODE = 'SB400';
        END IF;

        -- [v2.1] mod de rezervare: intreaga facilitate sau pe locuri
        IF v_fac.booking_mode = 'EXCLUSIVE' THEN
            NEW.seats := 1;
            NEW.exclusive_slot := TRUE;       -- suprapunerile le blocheaza constrangerea EXCLUDE
        ELSE
            NEW.exclusive_slot := FALSE;
            IF NEW.seats > v_fac.capacity THEN
                RAISE EXCEPTION 'Facilitatea are maximum % locuri', v_fac.capacity USING ERRCODE = 'SB400';
            END IF;
            -- blocheaza randul facilitatii ca doua rezervari simultane sa nu depaseasca capacitatea
            PERFORM 1 FROM sport_facilities WHERE facility_id = NEW.facility_id FOR UPDATE;
            SELECT COALESCE(SUM(b.seats), 0) INTO v_taken
              FROM bookings b
             WHERE b.facility_id = NEW.facility_id
               AND b.status NOT IN ('CANCELLED', 'EXPIRED')
               AND tstzrange(b.start_time, b.end_time, '[)') && tstzrange(NEW.start_time, NEW.end_time, '[)');
            IF v_taken + NEW.seats > v_fac.capacity THEN
                RAISE EXCEPTION 'Locuri insuficiente: libere %, cerute %',
                    v_fac.capacity - v_taken, NEW.seats USING ERRCODE = 'SB409';
            END IF;
        END IF;

        IF NEW.status IN ('INITIATED', 'PENDING_PAYMENT') AND NEW.hold_expires_at IS NULL THEN
            NEW.hold_expires_at := now() + INTERVAL '5 minutes';
        END IF;
    ELSE  -- UPDATE
        IF (NEW.user_id, NEW.facility_id, NEW.start_time, NEW.end_time, NEW.seats)
           IS DISTINCT FROM (OLD.user_id, OLD.facility_id, OLD.start_time, OLD.end_time, OLD.seats) THEN
            RAISE EXCEPTION 'Utilizatorul/facilitatea/intervalul/locurile nu se modifica; anuleaza si creeaza o rezervare noua'
                USING ERRCODE = 'SB400';
        END IF;
        IF NEW.status IS DISTINCT FROM OLD.status THEN
            IF NOT (
                (OLD.status = 'INITIATED'       AND NEW.status IN ('PENDING_PAYMENT', 'CONFIRMED', 'CANCELLED')) OR
                (OLD.status = 'PENDING_PAYMENT' AND NEW.status IN ('CONFIRMED', 'CANCELLED')) OR
                (OLD.status = 'CONFIRMED'       AND NEW.status IN ('CHECKED_IN', 'CANCELLED', 'EXPIRED')) OR
                (OLD.status = 'CHECKED_IN'      AND NEW.status = 'COMPLETED')
            ) THEN
                RAISE EXCEPTION 'Tranzitie de status interzisa: % -> %', OLD.status, NEW.status
                    USING ERRCODE = 'SB400';
            END IF;
            IF NEW.status = 'CANCELLED' AND NEW.cancelled_at IS NULL THEN
                NEW.cancelled_at := now();
            END IF;
            IF NEW.status NOT IN ('INITIATED', 'PENDING_PAYMENT') THEN
                NEW.hold_expires_at := NULL;
            END IF;
        END IF;
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_bookings_biu
    BEFORE INSERT OR UPDATE ON bookings
    FOR EACH ROW EXECUTE FUNCTION trg_bookings_biu();

-- 9.4 TRIGGER: la anulare/expirare/finalizare: echipamentele revin in stoc, platile in asteptare devin FAILED
CREATE OR REPLACE FUNCTION trg_bookings_after_terminal() RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    UPDATE equipment e
       SET available_stock = e.available_stock + be.quantity
      FROM booking_equipment be
     WHERE be.booking_id = NEW.booking_id AND be.equipment_id = e.equipment_id;
    UPDATE payments SET payment_status = 'FAILED'
     WHERE booking_id = NEW.booking_id AND payment_status = 'PENDING';
    RETURN NULL;
END $$;

CREATE TRIGGER trg_bookings_after_terminal
    AFTER UPDATE OF status ON bookings
    FOR EACH ROW
    WHEN (NEW.status IN ('CANCELLED', 'EXPIRED', 'COMPLETED') AND OLD.status IS DISTINCT FROM NEW.status)
    EXECUTE FUNCTION trg_bookings_after_terminal();

-- 9.5 TRIGGER pe booking_equipment: stoc, cost, total rezervare
CREATE OR REPLACE FUNCTION trg_booking_equipment_bi() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_b bookings%ROWTYPE;
    v_e equipment%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM bookings WHERE booking_id = NEW.booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rezervarea % nu exista', NEW.booking_id USING ERRCODE = 'SB404';
    END IF;
    IF v_b.status NOT IN ('INITIATED', 'PENDING_PAYMENT') THEN
        RAISE EXCEPTION 'Echipamentul se poate adauga doar inainte de plata (status curent: %)', v_b.status
            USING ERRCODE = 'SB409';
    END IF;

    SELECT * INTO v_e FROM equipment WHERE equipment_id = NEW.equipment_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Echipamentul % nu exista', NEW.equipment_id USING ERRCODE = 'SB404';
    END IF;
    IF v_e.available_stock < NEW.quantity THEN
        RAISE EXCEPTION 'Stoc insuficient pentru "%": disponibil %, cerut %',
            v_e.name, v_e.available_stock, NEW.quantity USING ERRCODE = 'SB409';
    END IF;

    NEW.cost := round(NEW.quantity * v_e.hourly_fee * fn_booking_hours(v_b.start_time, v_b.end_time), 2);
    UPDATE equipment SET available_stock = available_stock - NEW.quantity WHERE equipment_id = NEW.equipment_id;
    UPDATE bookings  SET equipment_amount = equipment_amount + NEW.cost,
                         total_amount     = total_amount     + NEW.cost
     WHERE booking_id = NEW.booking_id;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_booking_equipment_bi
    BEFORE INSERT ON booking_equipment
    FOR EACH ROW EXECUTE FUNCTION trg_booking_equipment_bi();

-- 9.6 TRIGGER pe profile: rolul utilizatorului trebuie sa corespunda profilului
CREATE OR REPLACE FUNCTION trg_profile_role_check() RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    v_role user_role_enum;
BEGIN
    SELECT role_type INTO v_role FROM users WHERE user_id = NEW.user_id;
    IF v_role IS DISTINCT FROM TG_ARGV[0]::user_role_enum THEN
        RAISE EXCEPTION 'Profilul % nu se potriveste cu rolul % al utilizatorului %',
            TG_TABLE_NAME, v_role, NEW.user_id USING ERRCODE = 'SB400';
    END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER trg_student_role   BEFORE INSERT OR UPDATE ON student_profiles
    FOR EACH ROW EXECUTE FUNCTION trg_profile_role_check('STUDENT');
CREATE TRIGGER trg_professor_role BEFORE INSERT OR UPDATE ON professor_profiles
    FOR EACH ROW EXECUTE FUNCTION trg_profile_role_check('PROFESSOR');
CREATE TRIGGER trg_amateur_role   BEFORE INSERT OR UPDATE ON amateur_profiles
    FOR EACH ROW EXECUTE FUNCTION trg_profile_role_check('AMATEUR');

-- 9.7 Inregistrare utilizator + profil intr-un singur apel (POST /auth/register) [v2.1]
-- Parola trebuie sa vina deja hash-uita cu bcrypt din backend. Doar rolurile publice se pot inregistra.
CREATE OR REPLACE FUNCTION register_user(p_full_name VARCHAR, p_email VARCHAR, p_phone VARCHAR,
                                         p_password_hash VARCHAR,
                                         p_role user_role_enum DEFAULT 'STUDENT',
                                         p_matricol VARCHAR DEFAULT NULL, p_faculty VARCHAR DEFAULT NULL,
                                         p_study_year INT DEFAULT NULL,
                                         p_department VARCHAR DEFAULT NULL, p_academic_title VARCHAR DEFAULT NULL,
                                         p_cnp_hash VARCHAR DEFAULT NULL, p_organization VARCHAR DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_id INT;
BEGIN
    IF p_role NOT IN ('STUDENT', 'PROFESSOR', 'AMATEUR') THEN
        RAISE EXCEPTION 'Conturile de personal se creeaza doar de administrator' USING ERRCODE = 'SB403';
    END IF;
    INSERT INTO users (full_name, email, phone_number, password_hash, role_type)
    VALUES (p_full_name, p_email, p_phone, p_password_hash, p_role)
    RETURNING user_id INTO v_id;

    IF p_role = 'STUDENT' THEN
        INSERT INTO student_profiles (user_id, matricol_number, faculty, study_year)
        VALUES (v_id, p_matricol, p_faculty, p_study_year);
    ELSIF p_role = 'PROFESSOR' THEN
        INSERT INTO professor_profiles (user_id, department, academic_title)
        VALUES (v_id, p_department, p_academic_title);
    ELSE
        INSERT INTO amateur_profiles (user_id, cnp_hash, organization)
        VALUES (v_id, p_cnp_hash, p_organization);
    END IF;
    RETURN v_id;
END $$;

-- 9.8 Creare rezervare (INITIATED, slot blocat 5 minute, pret detaliat dupa rol/reducere).
-- Codul QR NU exista inca: se genereaza abia dupa plata (CONFIRMED).
CREATE OR REPLACE FUNCTION create_booking(p_user_id INT, p_facility_id INT,
                                          p_start TIMESTAMPTZ, p_end TIMESTAMPTZ,
                                          p_seats INT DEFAULT 1, p_reminder BOOLEAN DEFAULT TRUE)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_tariff INT;
    v_p      RECORD;
    v_id     INT;
BEGIN
    IF p_seats IS NULL OR p_seats < 1 THEN
        RAISE EXCEPTION 'Numarul de locuri trebuie sa fie cel putin 1' USING ERRCODE = 'SB400';
    END IF;
    SELECT t.tariff_id INTO v_tariff
      FROM tariffs t JOIN users u ON u.role_type = t.role_type
     WHERE u.user_id = p_user_id AND u.is_active;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Utilizator inexistent, inactiv sau fara drept de rezervare' USING ERRCODE = 'SB403';
    END IF;

    SELECT * INTO v_p FROM fn_price_breakdown(p_user_id, p_facility_id, p_start, p_end, p_seats);

    INSERT INTO bookings (user_id, facility_id, tariff_id, start_time, end_time, seats,
                          base_amount, discount_amount, total_amount, reminder_enabled, status)
    VALUES (p_user_id, p_facility_id, v_tariff, p_start, p_end, p_seats,
            v_p.price_base, v_p.price_discount, v_p.price_total, p_reminder, 'INITIATED')
    RETURNING booking_id INTO v_id;
    RETURN v_id;
END $$;

-- 9.9 Uz intern: confirma rezervarea si genereaza codul QR
-- (backend-ul poate inlocui payload-ul cu un token semnat JWT/HMAC)
CREATE OR REPLACE FUNCTION fn_confirm_booking(p_booking_id INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    UPDATE bookings SET status = 'CONFIRMED' WHERE booking_id = p_booking_id;
    INSERT INTO qr_codes (booking_id, encrypted_payload)
    VALUES (p_booking_id, 'CSB-' || p_booking_id || '-' || gen_random_uuid());
END $$;

-- 9.10 Rezervare cu cost 0 (acces gratuit) -> confirmare fara plata
CREATE OR REPLACE FUNCTION confirm_free_booking(p_booking_id INT) RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_b bookings%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rezervarea % nu exista', p_booking_id USING ERRCODE = 'SB404';
    END IF;
    IF v_b.total_amount > 0 THEN
        RAISE EXCEPTION 'Rezervarea are cost (% RON); foloseste initiate_payment', v_b.total_amount
            USING ERRCODE = 'SB400';
    END IF;
    IF v_b.status <> 'INITIATED' THEN
        RAISE EXCEPTION 'Rezervarea nu este in starea INITIATED (%)', v_b.status USING ERRCODE = 'SB409';
    END IF;
    PERFORM fn_confirm_booking(p_booking_id);
END $$;

-- 9.11 Utilizatorul a deschis ecranul de plata (fara a crea o tranzactie)
CREATE OR REPLACE FUNCTION start_payment(p_booking_id INT) RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    UPDATE bookings SET status = 'PENDING_PAYMENT'
     WHERE booking_id = p_booking_id AND status = 'INITIATED';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rezervarea % nu poate trece in PENDING_PAYMENT', p_booking_id USING ERRCODE = 'SB409';
    END IF;
END $$;

-- 9.12 [v2.1] POST /bookings/{id}/pay: creeaza tranzactia PENDING (ex. PaymentIntent Stripe).
-- Se poate apela din nou dupa o plata esuata ("Reincearca plata"): tranzactia veche devine FAILED.
CREATE OR REPLACE FUNCTION initiate_payment(p_booking_id INT,
                                            p_method VARCHAR DEFAULT 'CARD_ONLINE',
                                            p_transaction_ref VARCHAR DEFAULT NULL)
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_b   bookings%ROWTYPE;
    v_pid INT;
BEGIN
    SELECT * INTO v_b FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rezervarea % nu exista', p_booking_id USING ERRCODE = 'SB404';
    END IF;
    IF v_b.status NOT IN ('INITIATED', 'PENDING_PAYMENT') THEN
        RAISE EXCEPTION 'Rezervarea nu asteapta plata (status: %)', v_b.status USING ERRCODE = 'SB409';
    END IF;
    IF v_b.hold_expires_at IS NOT NULL AND v_b.hold_expires_at < now() THEN
        RAISE EXCEPTION 'Au trecut cele 5 minute de blocare a slotului' USING ERRCODE = 'SB400';
    END IF;
    IF v_b.total_amount <= 0 THEN
        RAISE EXCEPTION 'Rezervarea este gratuita; foloseste confirm_free_booking' USING ERRCODE = 'SB400';
    END IF;

    UPDATE payments SET payment_status = 'FAILED'
     WHERE booking_id = p_booking_id AND payment_status = 'PENDING';
    IF v_b.status = 'INITIATED' THEN
        UPDATE bookings SET status = 'PENDING_PAYMENT' WHERE booking_id = p_booking_id;
    END IF;

    INSERT INTO payments (booking_id, amount, payment_method, transaction_ref, payment_status)
    VALUES (p_booking_id, v_b.total_amount, p_method,
            COALESCE(p_transaction_ref, 'TXN-' || gen_random_uuid()), 'PENDING')
    RETURNING payment_id INTO v_pid;
    RETURN v_pid;
END $$;

-- 9.13 [v2.1] Webhook-ul procesatorului (ex. payment_intent.succeeded / payment_failed), idempotent.
--   succes -> SUCCESS + CONFIRMED + cod QR
--   esec   -> FAILED; rezervarea ramane PENDING_PAYMENT pana expira cele 5 minute (se poate reincerca)
-- Daca rezervarea a fost deja anulata/expirata, functia da eroare SB409: backend-ul trebuie sa ramburseze tranzactia.
CREATE OR REPLACE FUNCTION complete_payment(p_transaction_ref VARCHAR, p_success BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_booking_id INT;
    v_p payments%ROWTYPE;
    v_b bookings%ROWTYPE;
BEGIN
    -- ordinea blocarilor: intai rezervarea, apoi plata (la fel ca initiate_payment) -> fara deadlock
    SELECT booking_id INTO v_booking_id FROM payments WHERE transaction_ref = p_transaction_ref;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Tranzactia % nu exista', p_transaction_ref USING ERRCODE = 'SB404';
    END IF;
    SELECT * INTO v_b FROM bookings WHERE booking_id = v_booking_id FOR UPDATE;
    SELECT * INTO v_p FROM payments WHERE transaction_ref = p_transaction_ref FOR UPDATE;

    IF v_p.payment_status = 'SUCCESS' AND p_success     THEN RETURN; END IF;   -- webhook repetat
    IF v_p.payment_status = 'FAILED'  AND NOT p_success THEN RETURN; END IF;
    IF v_p.payment_status <> 'PENDING' THEN
        RAISE EXCEPTION 'Tranzactia % este deja in starea %', p_transaction_ref, v_p.payment_status
            USING ERRCODE = 'SB409';
    END IF;

    IF p_success THEN
        IF v_b.status <> 'PENDING_PAYMENT' THEN
            RAISE EXCEPTION 'Rezervarea nu mai asteapta plata (status: %); ramburseaza tranzactia', v_b.status
                USING ERRCODE = 'SB409';
        END IF;
        -- plata sosita putin dupa cele 5 minute, dar inainte ca jobul sa anuleze rezervarea, este acceptata
        UPDATE payments SET payment_status = 'SUCCESS', processed_at = now() WHERE payment_id = v_p.payment_id;
        PERFORM fn_confirm_booking(v_b.booking_id);
    ELSE
        UPDATE payments SET payment_status = 'FAILED', processed_at = now() WHERE payment_id = v_p.payment_id;
    END IF;
END $$;

-- 9.14 Varianta simulata (MVP "Demonstrativ", teste, seed): initiere + rezultat intr-un apel
CREATE OR REPLACE FUNCTION register_payment(p_booking_id INT, p_method VARCHAR,
                                            p_transaction_ref VARCHAR, p_success BOOLEAN)
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM initiate_payment(p_booking_id, p_method, p_transaction_ref);
    PERFORM complete_payment(p_transaction_ref, p_success);
END $$;

-- 9.15 Anulare (minim 24h inainte pentru rezervari confirmate). p_now permite testarea.
CREATE OR REPLACE FUNCTION cancel_booking(p_booking_id INT, p_user_id INT,
                                          p_now TIMESTAMPTZ DEFAULT now())
RETURNS VOID LANGUAGE plpgsql AS $$
DECLARE
    v_b bookings%ROWTYPE;
BEGIN
    SELECT * INTO v_b FROM bookings WHERE booking_id = p_booking_id FOR UPDATE;
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Rezervarea % nu exista', p_booking_id USING ERRCODE = 'SB404';
    END IF;
    IF v_b.user_id <> p_user_id THEN
        RAISE EXCEPTION 'Nu poti anula rezervarea altui utilizator' USING ERRCODE = 'SB403';
    END IF;
    IF v_b.status = 'CONFIRMED' THEN
        IF v_b.start_time - p_now < INTERVAL '24 hours' THEN
            RAISE EXCEPTION 'Anularea este posibila doar cu minimum 24 de ore inainte de start'
                USING ERRCODE = 'SB400';
        END IF;
    ELSIF v_b.status NOT IN ('INITIATED', 'PENDING_PAYMENT') THEN
        RAISE EXCEPTION 'O rezervare cu statusul % nu mai poate fi anulata', v_b.status USING ERRCODE = 'SB400';
    END IF;

    UPDATE bookings SET status = 'CANCELLED'    WHERE booking_id = p_booking_id;
    UPDATE qr_codes SET is_valid = FALSE        WHERE booking_id = p_booking_id;
    -- doar starea din BD; rambursarea reala (Stripe/Netopia) o face backend-ul
    UPDATE payments SET payment_status = 'REFUNDED'
     WHERE booking_id = p_booking_id AND payment_status = 'SUCCESS';
END $$;

-- 9.16 Validare QR (POST /qr/validate). Returneaza datele afisate pe ecranul "Scanare cod QR". [v2.1: tabel]
CREATE OR REPLACE FUNCTION validate_qr(p_payload TEXT, p_receptionist_id INT,
                                       p_now TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (o_booking_id INT, o_user_name VARCHAR, o_role_type user_role_enum,
               o_facility_name VARCHAR, o_start_time TIMESTAMPTZ, o_end_time TIMESTAMPTZ, o_seats INT)
LANGUAGE plpgsql AS $$
DECLARE
    r RECORD;
BEGIN
    PERFORM 1 FROM users
      WHERE user_id = p_receptionist_id AND is_active AND role_type IN ('RECEPTIONIST', 'ADMIN');
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Doar personalul de la receptie poate valida coduri QR' USING ERRCODE = 'SB403';
    END IF;

    SELECT q.qr_id, q.is_valid, q.is_scanned, b.booking_id, b.status, b.start_time, b.end_time
      INTO r
      FROM qr_codes q JOIN bookings b ON b.booking_id = q.booking_id
     WHERE q.encrypted_payload = p_payload
       FOR UPDATE OF q, b;

    IF NOT FOUND      THEN RAISE EXCEPTION 'Cod QR necunoscut' USING ERRCODE = 'SB404'; END IF;
    IF NOT r.is_valid THEN RAISE EXCEPTION 'Cod QR invalidat (rezervare anulata)' USING ERRCODE = 'SB403'; END IF;
    IF r.is_scanned   THEN RAISE EXCEPTION 'Cod QR deja folosit' USING ERRCODE = 'SB403'; END IF;
    IF r.status <> 'CONFIRMED' THEN
        RAISE EXCEPTION 'Rezervarea nu este confirmata (status: %)', r.status USING ERRCODE = 'SB403';
    END IF;
    -- acces permis cu 15 minute inainte de start pana la sfarsitul intervalului
    IF p_now < r.start_time - INTERVAL '15 minutes' OR p_now > r.end_time THEN
        RAISE EXCEPTION 'Acces in afara intervalului rezervat' USING ERRCODE = 'SB403';
    END IF;

    UPDATE qr_codes SET is_scanned = TRUE, scanned_at = p_now,
                        scanned_by_receptionist_id = p_receptionist_id
     WHERE qr_id = r.qr_id;
    UPDATE bookings SET status = 'CHECKED_IN' WHERE booking_id = r.booking_id;

    RETURN QUERY
    SELECT b.booking_id, u.full_name, u.role_type, f.name, b.start_time, b.end_time, b.seats
      FROM bookings b
      JOIN users u            ON u.user_id = b.user_id
      JOIN sport_facilities f ON f.facility_id = b.facility_id
     WHERE b.booking_id = r.booking_id;
END $$;

-- 9.17 Job periodic (node-cron, la 1 minut)
CREATE OR REPLACE FUNCTION expire_stale_bookings(p_now TIMESTAMPTZ DEFAULT now())
RETURNS INT LANGUAGE plpgsql AS $$
DECLARE
    v_n INT := 0;
    v_k INT;
BEGIN
    UPDATE bookings SET status = 'CANCELLED'          -- blocarea de 5 minute a expirat
     WHERE status IN ('INITIATED', 'PENDING_PAYMENT') AND hold_expires_at <= p_now;
    GET DIAGNOSTICS v_k = ROW_COUNT;  v_n := v_n + v_k;

    UPDATE bookings SET status = 'EXPIRED'            -- no-show
     WHERE status = 'CONFIRMED' AND end_time <= p_now;
    GET DIAGNOSTICS v_k = ROW_COUNT;  v_n := v_n + v_k;

    UPDATE bookings SET status = 'COMPLETED'
     WHERE status = 'CHECKED_IN' AND end_time <= p_now;
    GET DIAGNOSTICS v_k = ROW_COUNT;  v_n := v_n + v_k;
    RETURN v_n;
END $$;

-- 9.18 [v2.1] Remindere: returneaza si marcheaza ATOMIC rezervarile al caror reminder trebuie trimis acum
-- (se apeleaza din node-cron; pot rula mai multe instante de backend fara dubluri)
CREATE OR REPLACE FUNCTION claim_due_reminders(p_now TIMESTAMPTZ DEFAULT now())
RETURNS TABLE (booking_id INT, user_id INT, email VARCHAR, full_name VARCHAR,
               facility_name VARCHAR, start_time TIMESTAMPTZ)
LANGUAGE sql AS $$
    UPDATE bookings b SET reminder_sent_at = p_now
      FROM users u, sport_facilities f
     WHERE u.user_id = b.user_id AND f.facility_id = b.facility_id
       AND b.status = 'CONFIRMED' AND b.reminder_enabled AND b.reminder_sent_at IS NULL
       AND u.reminder_minutes_before IS NOT NULL
       AND p_now >= b.start_time - make_interval(mins => u.reminder_minutes_before)
       AND p_now <  b.start_time
    RETURNING b.booking_id, u.user_id, u.email, u.full_name, f.name, b.start_time
$$;

-- 9.19 Calendar (GET /facilities/{id}/availability) [v2.1: sloturi pe facilitate, locuri, zile libere]
--   capacity   = locuri / slot (1 pentru facilitatile EXCLUSIVE)
--   seats_left = locuri ramase ("Disponibil - 6/10 locuri")
--   is_free    = slot in viitor si cu locuri libere
--   overlaps_own_booking = suprapus cu o rezervare activa a utilizatorului p_user_id ("slot dezactivat" in Figma)
-- Zi in care facilitatea e inchisa => zero randuri.
CREATE OR REPLACE FUNCTION get_available_slots(p_facility_id INT, p_date DATE, p_user_id INT DEFAULT NULL)
RETURNS TABLE (slot_start TIMESTAMPTZ, slot_end TIMESTAMPTZ, capacity INT, seats_left INT,
               is_free BOOLEAN, overlaps_own_booking BOOLEAN)
LANGUAGE sql STABLE AS $$
    SELECT s.st,
           s.st + make_interval(mins => f.slot_minutes),
           cap.c,
           GREATEST(cap.c - tk.n, 0),
           (s.st > now() AND GREATEST(cap.c - tk.n, 0) > 0),
           own.o
      FROM sport_facilities f
     CROSS JOIN LATERAL generate_series(p_date + f.opens_at,
                                        p_date + f.closes_at - make_interval(mins => f.slot_minutes),
                                        make_interval(mins => f.slot_minutes)) AS g(local_ts)
     CROSS JOIN LATERAL (SELECT g.local_ts AT TIME ZONE 'Europe/Bucharest' AS st) s
     CROSS JOIN LATERAL (SELECT CASE WHEN f.booking_mode = 'SHARED' THEN f.capacity ELSE 1 END AS c) cap
     CROSS JOIN LATERAL (
         SELECT COALESCE(SUM(b.seats), 0)::INT AS n
           FROM bookings b
          WHERE b.facility_id = f.facility_id
            AND b.status NOT IN ('CANCELLED', 'EXPIRED')
            AND tstzrange(b.start_time, b.end_time, '[)')
                && tstzrange(s.st, s.st + make_interval(mins => f.slot_minutes), '[)')) tk
     CROSS JOIN LATERAL (
         SELECT (p_user_id IS NOT NULL AND EXISTS (
                    SELECT 1 FROM bookings ub
                     WHERE ub.user_id = p_user_id
                       AND ub.status NOT IN ('CANCELLED', 'EXPIRED')
                       AND tstzrange(ub.start_time, ub.end_time, '[)')
                           && tstzrange(s.st, s.st + make_interval(mins => f.slot_minutes), '[)'))) AS o) own
     WHERE f.facility_id = p_facility_id AND f.is_active
       AND EXTRACT(ISODOW FROM p_date)::SMALLINT = ANY (f.open_days)
     ORDER BY s.st
$$;

-- =====================================================================
-- 10. VIEW-URI
-- =====================================================================
-- [v2.1] Cardul facilitatii din ecranul "Facilitati" / "Detalii" / "Harta" (GET /facilities)
CREATE VIEW v_facility_catalog AS
SELECT f.facility_id, f.name, f.sport_type, f.category, f.booking_mode, f.capacity, f.slot_minutes,
       f.base_price_per_hour,
       round(f.base_price_per_hour * f.slot_minutes / 60.0, 2)                      AS price_per_slot,
       fn_ron_to_eur(round(f.base_price_per_hour * f.slot_minutes / 60.0, 2))       AS price_per_slot_eur,
       f.has_lighting, f.is_active, f.opens_at, f.closes_at, f.open_days,
       (EXTRACT(ISODOW FROM (now() AT TIME ZONE 'Europe/Bucharest'))::SMALLINT = ANY (f.open_days)) AS open_today,
       (f.early_booking_days IS NOT NULL) AS has_early_discount,
       f.early_booking_days, f.early_booking_discount,
       l.location_id, l.zone_name, l.building_name AS location_name, l.address, l.geo_coordinates, l.contact_phone
  FROM sport_facilities f
  JOIN campus_locations l ON l.location_id = f.location_id;

-- [v2.1] "Rezervarile mele", "Rezervare confirmata", recepție. Filtrare: WHERE user_id = :id
CREATE VIEW v_booking_details AS
SELECT b.booking_id,
       'SC-' || to_char(b.booking_date, 'DDMMYY') || '-' || lpad(b.booking_id::TEXT, 3, '0') AS booking_code,
       b.user_id, u.full_name, u.role_type,
       b.facility_id, f.name AS facility, f.sport_type, l.building_name,
       b.seats, b.start_time, b.end_time,
       b.base_amount, b.discount_amount, b.equipment_amount, b.total_amount,
       fn_ron_to_eur(b.total_amount) AS total_amount_eur,
       b.status, b.hold_expires_at, b.reminder_enabled,
       CASE WHEN q.is_valid THEN q.encrypted_payload END AS qr_payload,   -- NULL pana la plata si dupa anulare
       q.is_valid   AS qr_valid,
       q.is_scanned AS qr_scanned,
       (SELECT p.payment_status FROM payments p
         WHERE p.booking_id = b.booking_id
         ORDER BY p.processed_at DESC, p.payment_id DESC LIMIT 1) AS last_payment_status,
       (b.status IN ('INITIATED', 'PENDING_PAYMENT', 'CONFIRMED', 'CHECKED_IN')
        AND b.end_time > now()) AS is_upcoming,                          -- tab "Viitoare" vs "Istoric"
       b.created_at
  FROM bookings b
  JOIN users u            ON u.user_id = b.user_id
  JOIN sport_facilities f ON f.facility_id = b.facility_id
  JOIN campus_locations l ON l.location_id = f.location_id
  LEFT JOIN qr_codes q    ON q.booking_id = b.booking_id;

-- =====================================================================
-- 11. DATE DE TEST (SEED)
-- =====================================================================
INSERT INTO app_settings (setting_key, setting_value, description) VALUES
('eur_ron_rate', '5.00', 'Curs fix MVP: 1 EUR = 5 RON');

INSERT INTO tariffs (role_type, discount_percent, is_free_access, description) VALUES
('STUDENT',   50.00, FALSE, 'Tarif redus 50% pentru studenți universitari'),
('PROFESSOR', 30.00, FALSE, 'Tarif redus 30% pentru cadre didactice'),
('AMATEUR',    0.00, FALSE, 'Tarif standard întreg pentru publicul extern');

INSERT INTO campus_locations (zone_name, building_name, address, geo_coordinates, contact_phone) VALUES
('Campus Principal',   'Bază sportivă',          'Str. Universității nr. 13', '47.6512, 26.2541', '0330000000'),
('Complex Studențesc', 'Complex sportiv, corp A', 'Aleea Căminelor nr. 4',     '47.6540, 26.2580', '0330000000'),
('Complex Studențesc', 'Complex sportiv, corp B', 'Aleea Căminelor nr. 6',     '47.6545, 26.2590', '0330000000');

-- ids: 1 fotbal, 2 tenis, 3 bazin, 4 fitness, 5 sauna
INSERT INTO sport_facilities
    (location_id, name, sport_type, category, booking_mode, capacity, base_price_per_hour, slot_minutes,
     has_lighting, opens_at, closes_at, open_days, early_booking_days, early_booking_discount) VALUES
((SELECT location_id FROM campus_locations WHERE building_name = 'Bază sportivă'),
 'Teren Fotbal Sintetic Nocturnă #1', 'Fotbal',  'Sporturi', 'EXCLUSIVE', 14, 90.00, 60, TRUE,  '08:00', '23:00', ARRAY[1,2,3,4,5,6,7]::SMALLINT[], NULL, NULL),
((SELECT location_id FROM campus_locations WHERE building_name = 'Bază sportivă'),
 'Teren de tenis',                    'Tenis',   'Sporturi', 'EXCLUSIVE',  4, 40.00, 60, TRUE,  '08:00', '21:00', ARRAY[1,2,3,4,5,6,7]::SMALLINT[], NULL, NULL),
((SELECT location_id FROM campus_locations WHERE building_name = 'Complex sportiv, corp A'),
 'Bazin',                             'Natație', 'Înot',     'SHARED',    10, 25.00, 60, FALSE, '08:00', '21:00', ARRAY[1,2,3,4,5]::SMALLINT[],   3,    10.00),
((SELECT location_id FROM campus_locations WHERE building_name = 'Complex sportiv, corp A'),
 'Sală Polivalentă & Fitness',        'Fitness', 'Sporturi', 'SHARED',    25, 30.00, 60, FALSE, '08:00', '22:00', ARRAY[1,2,3,4,5,6,7]::SMALLINT[], NULL, NULL),
((SELECT location_id FROM campus_locations WHERE building_name = 'Complex sportiv, corp B'),
 'Saună',                             'Saună',   'Relaxare', 'SHARED',     6, 40.00, 30, FALSE, '08:00', '21:00', ARRAY[1,2,3,4,5,6,7]::SMALLINT[], NULL, NULL);

INSERT INTO equipment (name, sport_category, available_stock, hourly_fee) VALUES
('Minge Fotbal Nike Pro',       'Fotbal',   10, 10.00),
('Set 2 Rachete Tenis + Mingi', 'Tenis',     8, 15.00),
('Ochelari de înot',            'Natație',  15,  4.00),
('Bonetă de înot',              'Natație',  15,  3.00),
('Plută de înot',               'Natație',  10,  3.00);

-- NOTA: hash-ul de mai jos este doar un placeholder; parolele reale le genereaza backend-ul cu bcrypt.
INSERT INTO users (full_name, email, phone_number, password_hash, role_type) VALUES
('Cosmin Flocea',          'cosmin.flocea@student.ro',     '0721111111', '$2b$10$PLACEHOLDER.HASH.DEMO', 'STUDENT'),
('Alexandra Andrieș',      'alexandra.andries@student.ro', '0722222222', '$2b$10$PLACEHOLDER.HASH.DEMO', 'STUDENT'),
('Sebastian Strugar',      'sebastian.strugar@student.ro', '0723333333', '$2b$10$PLACEHOLDER.HASH.DEMO', 'STUDENT'),
('Prof. Dan Popescu',      'dan.popescu@univ.ro',          '0744444444', '$2b$10$PLACEHOLDER.HASH.DEMO', 'PROFESSOR'),
('Mihai Ionescu',          'mihai.ionescu@gmail.com',      '0755555555', '$2b$10$PLACEHOLDER.HASH.DEMO', 'AMATEUR'),
('Recepție Bază Sportivă', 'receptie@campussports.ro',     '0766666666', '$2b$10$PLACEHOLDER.HASH.DEMO', 'RECEPTIONIST');

INSERT INTO student_profiles (user_id, matricol_number, faculty, study_year)
SELECT u.user_id, v.mat, 'Facultatea de Inginerie Electrică și Știința Calculatoarelor', 3
  FROM (VALUES ('cosmin.flocea@student.ro', '3BITS-001'),
               ('alexandra.andries@student.ro', '3BITS-002'),
               ('sebastian.strugar@student.ro', '3BITS-003')) v(email, mat)
  JOIN users u ON u.email = v.email;

INSERT INTO professor_profiles (user_id, department, academic_title)
SELECT user_id, 'Departamentul de Calculatoare', 'Conf. Dr. Ing.' FROM users WHERE email = 'dan.popescu@univ.ro';

INSERT INTO amateur_profiles (user_id, cnp_hash, organization)
SELECT user_id, NULL, 'Club Sportiv Amator' FROM users WHERE email = 'mihai.ionescu@gmail.com';

-- Rezervari de test, create prin functiile din sectiunea 9 (ca in aplicatie)
DO $$
DECLARE
    v_day  DATE := CURRENT_DATE + 1;
    v_b1   INT;
    v_b2   INT;
BEGIN
    -- 1) Student, fotbal, maine 18-19, + minge => 45 (50% din 90) + 10 = 55 RON, platita
    v_b1 := create_booking(
        (SELECT user_id FROM users WHERE email = 'cosmin.flocea@student.ro'),
        (SELECT facility_id FROM sport_facilities WHERE sport_type = 'Fotbal'),
        (v_day + TIME '18:00') AT TIME ZONE 'Europe/Bucharest',
        (v_day + TIME '19:00') AT TIME ZONE 'Europe/Bucharest');
    INSERT INTO booking_equipment (booking_id, equipment_id, quantity)
    VALUES (v_b1, (SELECT equipment_id FROM equipment WHERE sport_category = 'Fotbal'), 1);
    PERFORM register_payment(v_b1, 'CARD_ONLINE', 'TXN_SEED_0001', TRUE);

    -- 2) Amator, tenis, maine 10-12 => 2 x 40 = 80 RON (tarif standard), platita
    v_b2 := create_booking(
        (SELECT user_id FROM users WHERE email = 'mihai.ionescu@gmail.com'),
        (SELECT facility_id FROM sport_facilities WHERE sport_type = 'Tenis'),
        (v_day + TIME '10:00') AT TIME ZONE 'Europe/Bucharest',
        (v_day + TIME '12:00') AT TIME ZONE 'Europe/Bucharest');
    PERFORM register_payment(v_b2, 'CARD_ONLINE', 'TXN_SEED_0002', TRUE);
END $$;
