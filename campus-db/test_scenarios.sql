-- =====================================================================
-- TESTE pentru regulile de business (ruleaza dupa schema_campus_sports_v2.sql)
--   psql -U <user> -d campus_sports -v ON_ERROR_STOP=1 -f test_scenarios.sql
-- Totul ruleaza intr-o tranzactie care se anuleaza la final (ROLLBACK) -> nu murdareste datele.
-- Fiecare test afiseaza "OK Tn ..." sau opreste scriptul cu mesajul erorii.
-- Testele nu depind de ora la care ruleaza (date fixe in viitor / in trecut).
-- =====================================================================
\set ON_ERROR_STOP on
SET timezone TO 'Europe/Bucharest';
BEGIN;

-- helper: executa un SQL si cere ca el sa esueze cu un mesaj care contine p_pattern
-- (si, optional, cu SQLSTATE-ul p_state)
CREATE FUNCTION pg_temp.expect_error(q TEXT, p_pattern TEXT, p_state TEXT DEFAULT NULL) RETURNS VOID
LANGUAGE plpgsql AS $$
BEGIN
    BEGIN
        EXECUTE q;
    EXCEPTION WHEN OTHERS THEN
        IF SQLERRM NOT ILIKE '%' || p_pattern || '%' THEN
            RAISE EXCEPTION 'Eroare diferita decat cea asteptata. Asteptat: "%", primit: "%"', p_pattern, SQLERRM;
        END IF;
        IF p_state IS NOT NULL AND SQLSTATE <> p_state THEN
            RAISE EXCEPTION 'SQLSTATE gresit pentru "%": asteptat %, primit %', p_pattern, p_state, SQLSTATE;
        END IF;
        RETURN;
    END;
    RAISE EXCEPTION 'Trebuia sa esueze, dar a reusit: %', q;
END $$;

DO $$
DECLARE
    u_stud  INT := (SELECT user_id FROM users WHERE email = 'alexandra.andries@student.ro');
    u_stud2 INT := (SELECT user_id FROM users WHERE email = 'sebastian.strugar@student.ro');
    u_prof  INT := (SELECT user_id FROM users WHERE email = 'dan.popescu@univ.ro');
    u_rec   INT := (SELECT user_id FROM users WHERE email = 'receptie@campussports.ro');
    u_amat  INT := (SELECT user_id FROM users WHERE email = 'mihai.ionescu@gmail.com');
    f_foot  INT := (SELECT facility_id FROM sport_facilities WHERE sport_type = 'Fotbal');
    f_tenis INT := (SELECT facility_id FROM sport_facilities WHERE sport_type = 'Tenis');
    f_pool  INT := (SELECT facility_id FROM sport_facilities WHERE sport_type = 'Natație');
    f_sauna INT := (SELECT facility_id FROM sport_facilities WHERE sport_type = 'Saună');
    e_minge INT := (SELECT equipment_id FROM equipment WHERE sport_category = 'Fotbal');
    d3      DATE := CURRENT_DATE + 3;
    wd      DATE;            -- prima zi lucratoare >= d3 (bazinul functioneaza doar luni-vineri)
    sat     DATE;            -- o sambata >= d3
    s       TIMESTAMPTZ;
    sp      TIMESTAMPTZ;     -- 15:00 in ziua wd (bazin)
    b       INT;  b2 INT;  b3 INT;
    v_stock INT;
    v_payload TEXT;
    v_n     INT;
    rec     RECORD;
    new_u   INT;
BEGIN
    wd  := d3 + CASE EXTRACT(ISODOW FROM d3)::INT WHEN 6 THEN 2 WHEN 7 THEN 1 ELSE 0 END;
    sat := d3 + ((6 - EXTRACT(ISODOW FROM d3)::INT + 7) % 7);
    s   := (d3 + TIME '10:00') AT TIME ZONE 'Europe/Bucharest';
    sp  := (wd + TIME '15:00') AT TIME ZONE 'Europe/Bucharest';

    -- ---------- T1: tarife dupa rol (fotbal 90 RON/h) ----------
    IF fn_calculate_price(u_stud, f_foot, s, s + INTERVAL '1 hour')  <> 45.00  THEN RAISE EXCEPTION 'T1 student'; END IF;
    IF fn_calculate_price(u_prof, f_foot, s, s + INTERVAL '1 hour')  <> 63.00  THEN RAISE EXCEPTION 'T1 profesor'; END IF;
    IF fn_calculate_price(u_amat, f_foot, s, s + INTERVAL '2 hours') <> 180.00 THEN RAISE EXCEPTION 'T1 amator'; END IF;
    PERFORM pg_temp.expect_error(format('SELECT fn_calculate_price(%s,%s,%L,%L)', u_rec, f_foot, s, s + INTERVAL '1 hour'),
                                 'nu are un tarif', 'SB403');
    RAISE NOTICE 'OK T1 tarife: student 45, profesor 63, amator 180 pentru 2h; receptionerul nu are tarif';

    -- ---------- T2: suprapunere respinsa, intervale adiacente permise ----------
    b := create_booking(u_stud, f_foot, s, s + INTERVAL '1 hour');                           -- 10:00-11:00
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)',
        u_stud2, f_foot, s, s + INTERVAL '2 hours'), 'ex_bookings_no_overlap', '23P01');    -- 10:00-12:00 => suprapus
    PERFORM create_booking(u_stud2, f_foot, s + INTERVAL '1 hour', s + INTERVAL '2 hours');  -- 11:00-12:00 => OK
    PERFORM create_booking(u_stud2, f_tenis, s, s + INTERVAL '1 hour');                      -- alt teren, aceeasi ora => OK
    RAISE NOTICE 'OK T2 suprapunerea pe acelasi teren e respinsa (23P01); adiacent si alt teren sunt permise';

    -- ---------- T3: ora de program + trecut (zile fixe, independent de ora rularii) ----------
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_stud, f_foot,
        (d3 + TIME '06:00') AT TIME ZONE 'Europe/Bucharest', (d3 + TIME '07:00') AT TIME ZONE 'Europe/Bucharest'),
        'In afara programului', 'SB400');
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_stud, f_foot,
        (CURRENT_DATE - 1 + TIME '10:00') AT TIME ZONE 'Europe/Bucharest',
        (CURRENT_DATE - 1 + TIME '11:00') AT TIME ZONE 'Europe/Bucharest'), 'in trecut', 'SB400');
    RAISE NOTICE 'OK T3 in afara programului si in trecut sunt respinse';

    -- ---------- T4: echipament: stoc, cost, restituire, detaliere sume ----------
    SELECT available_stock INTO v_stock FROM equipment WHERE equipment_id = e_minge;
    INSERT INTO booking_equipment (booking_id, equipment_id, quantity) VALUES (b, e_minge, 2);
    SELECT * INTO rec FROM bookings WHERE booking_id = b;
    IF rec.total_amount <> 65.00 OR rec.base_amount <> 90.00 OR rec.discount_amount <> 45.00 OR rec.equipment_amount <> 20.00 THEN
        RAISE EXCEPTION 'T4 sume: base %, reducere %, echipament %, total % (asteptat 90 / 45 / 20 / 65)',
            rec.base_amount, rec.discount_amount, rec.equipment_amount, rec.total_amount;
    END IF;
    IF (SELECT available_stock FROM equipment WHERE equipment_id = e_minge) <> v_stock - 2 THEN RAISE EXCEPTION 'T4 stoc scazut'; END IF;
    PERFORM pg_temp.expect_error(format('INSERT INTO booking_equipment(booking_id,equipment_id,quantity) VALUES (%s,%s,%s)',
        b, (SELECT equipment_id FROM equipment WHERE sport_category = 'Tenis'), 999), 'Stoc insuficient', 'SB409');
    RAISE NOTICE 'OK T4 echipament: cost in total (90 - 45 + 20 = 65), stoc scazut, stoc insuficient respins';

    -- ---------- T5: plata cu succes -> CONFIRMED + QR ----------
    PERFORM start_payment(b);
    PERFORM register_payment(b, 'CARD_ONLINE', 'TXN_TEST_T5', TRUE);
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'CONFIRMED' THEN RAISE EXCEPTION 'T5 status'; END IF;
    IF (SELECT count(*) FROM qr_codes WHERE booking_id = b AND is_valid) <> 1 THEN RAISE EXCEPTION 'T5 QR'; END IF;
    PERFORM pg_temp.expect_error(format('SELECT register_payment(%s,''CARD_ONLINE'',''TXN_TEST_T5B'',true)', b),
                                 'nu asteapta plata', 'SB409');
    RAISE NOTICE 'OK T5 plata reusita => CONFIRMED + cod QR generat; dubla plata respinsa';

    -- ---------- T6: validare QR (returneaza datele pentru ecranul de scanare) ----------
    SELECT encrypted_payload INTO v_payload FROM qr_codes WHERE booking_id = b;
    PERFORM pg_temp.expect_error(format('SELECT * FROM validate_qr(%L,%s)', v_payload, u_stud), 'Doar personalul', 'SB403');
    PERFORM pg_temp.expect_error(format('SELECT * FROM validate_qr(%L,%s)', v_payload, u_rec), 'in afara intervalului', 'SB403');
    SELECT * INTO rec FROM validate_qr(v_payload, u_rec, s);                                 -- la ora 10:00 => OK
    IF rec.o_booking_id <> b OR rec.o_role_type <> 'STUDENT' OR rec.o_user_name <> 'Alexandra Andrieș'
       OR rec.o_facility_name NOT LIKE 'Teren Fotbal%' THEN RAISE EXCEPTION 'T6 date returnate: %', rec; END IF;
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'CHECKED_IN' THEN RAISE EXCEPTION 'T6 status'; END IF;
    PERFORM pg_temp.expect_error(format('SELECT * FROM validate_qr(%L,%s,%L)', v_payload, u_rec, s), 'deja folosit', 'SB403');
    PERFORM pg_temp.expect_error(format('SELECT * FROM validate_qr(%L,%s)', 'COD-INEXISTENT', u_rec), 'necunoscut', 'SB404');
    RAISE NOTICE 'OK T6 QR: doar recepție, doar in interval, o singura folosire; cod necunoscut = SB404';

    -- ---------- T7: finalizare automata + tranzitii interzise ----------
    v_n := expire_stale_bookings(s + INTERVAL '2 hours');
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'COMPLETED' THEN RAISE EXCEPTION 'T7 completed'; END IF;
    -- invariant: stoc disponibil + bucati ocupate in rezervari active = stocul initial (10)
    IF (SELECT available_stock FROM equipment WHERE equipment_id = e_minge)
       + COALESCE((SELECT sum(be.quantity) FROM booking_equipment be JOIN bookings bk ON bk.booking_id = be.booking_id
                    WHERE be.equipment_id = e_minge
                      AND bk.status IN ('INITIATED','PENDING_PAYMENT','CONFIRMED','CHECKED_IN')), 0) <> 10 THEN
        RAISE EXCEPTION 'T7 stocul nu a fost restituit corect';
    END IF;
    PERFORM pg_temp.expect_error(format('UPDATE bookings SET status=''CONFIRMED'' WHERE booking_id=%s', b), 'Tranzitie de status interzisa', 'SB400');
    RAISE NOTICE 'OK T7 CHECKED_IN -> COMPLETED (job), echipamentul revine in stoc, tranzitie interzisa respinsa';

    -- ---------- T8: anulare ----------
    s := (d3 + TIME '14:00') AT TIME ZONE 'Europe/Bucharest';
    b2 := create_booking(u_prof, f_foot, s, s + INTERVAL '1 hour');
    PERFORM register_payment(b2, 'CARD_ONLINE', 'TXN_TEST_T8', TRUE);
    PERFORM pg_temp.expect_error(format('SELECT cancel_booking(%s,%s)', b2, u_stud), 'altui utilizator', 'SB403');
    PERFORM pg_temp.expect_error(format('SELECT cancel_booking(%s,%s,%L)', b2, u_prof, s - INTERVAL '23 hours'), 'minimum 24 de ore', 'SB400');
    PERFORM cancel_booking(b2, u_prof, s - INTERVAL '25 hours');
    IF (SELECT status FROM bookings WHERE booking_id = b2) <> 'CANCELLED' THEN RAISE EXCEPTION 'T8 status'; END IF;
    IF (SELECT is_valid FROM qr_codes WHERE booking_id = b2) THEN RAISE EXCEPTION 'T8 QR trebuia invalidat'; END IF;
    IF (SELECT payment_status FROM payments WHERE booking_id = b2) <> 'REFUNDED' THEN RAISE EXCEPTION 'T8 refund'; END IF;
    IF (SELECT qr_payload FROM v_booking_details WHERE booking_id = b2) IS NOT NULL THEN RAISE EXCEPTION 'T8 qr_payload trebuia ascuns'; END IF;
    PERFORM create_booking(u_stud, f_foot, s, s + INTERVAL '1 hour');          -- slotul anulat se poate rezerva din nou
    RAISE NOTICE 'OK T8 anulare: refuzata <24h, permisa >=24h, QR invalidat, plata REFUNDED, slot eliberat';

    -- ---------- T9: plata esuata -> slot inca blocat, "Reincearca plata" reuseste ----------
    s := (d3 + TIME '16:00') AT TIME ZONE 'Europe/Bucharest';
    b := create_booking(u_stud, f_foot, s, s + INTERVAL '1 hour');
    PERFORM register_payment(b, 'CARD_ONLINE', 'TXN_TEST_T9_A', FALSE);
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'PENDING_PAYMENT' THEN RAISE EXCEPTION 'T9 status dupa esec'; END IF;
    IF (SELECT payment_status FROM payments WHERE transaction_ref = 'TXN_TEST_T9_A') <> 'FAILED' THEN RAISE EXCEPTION 'T9 plata FAILED'; END IF;
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_stud2, f_foot, s, s + INTERVAL '1 hour'),
                                 'ex_bookings_no_overlap', '23P01');                       -- slotul ramane blocat in timpul retry-ului
    PERFORM register_payment(b, 'CARD_ONLINE', 'TXN_TEST_T9_B', TRUE);                       -- retry
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'CONFIRMED' THEN RAISE EXCEPTION 'T9 status dupa retry'; END IF;
    RAISE NOTICE 'OK T9 plata respinsa => ramane PENDING_PAYMENT (slot blocat), retry reusit => CONFIRMED';

    -- ---------- T10: expirarea blocarii de 5 minute ----------
    s := (d3 + TIME '18:00') AT TIME ZONE 'Europe/Bucharest';
    b := create_booking(u_stud, f_foot, s, s + INTERVAL '1 hour');
    PERFORM register_payment(b, 'CARD_ONLINE', 'TXN_TEST_T10_A', FALSE);                     -- plata esuata, apoi utilizatorul abandoneaza
    IF expire_stale_bookings(now() + INTERVAL '1 minute') <> 0 THEN RAISE EXCEPTION 'T10 prea devreme'; END IF;
    IF expire_stale_bookings(now() + INTERVAL '6 minutes') < 1 THEN RAISE EXCEPTION 'T10 trebuia sa expire'; END IF;
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'CANCELLED' THEN RAISE EXCEPTION 'T10 status'; END IF;
    PERFORM create_booking(u_stud2, f_foot, s, s + INTERVAL '1 hour');                       -- slotul s-a eliberat
    RAISE NOTICE 'OK T10 rezervarea neplatita expira dupa 5 minute si elibereaza slotul';

    -- ---------- T11: no-show ----------
    s := (d3 + TIME '20:00') AT TIME ZONE 'Europe/Bucharest';
    b := create_booking(u_amat, f_foot, s, s + INTERVAL '1 hour');
    PERFORM register_payment(b, 'CARD_ONLINE', 'TXN_TEST_T11', TRUE);
    PERFORM expire_stale_bookings(s + INTERVAL '2 hours');
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'EXPIRED' THEN RAISE EXCEPTION 'T11 status'; END IF;
    RAISE NOTICE 'OK T11 rezervare confirmata dar nefolosita => EXPIRED (no-show)';

    -- ---------- T12: profil vs rol, rol fara tarif, email duplicat ----------
    PERFORM pg_temp.expect_error(format(
        'INSERT INTO professor_profiles(user_id,department,academic_title) VALUES (%s,''X'',''Y'')', u_stud), 'nu se potriveste cu rolul', 'SB400');
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_rec, f_foot,
        (d3 + TIME '09:00') AT TIME ZONE 'Europe/Bucharest', (d3 + TIME '10:00') AT TIME ZONE 'Europe/Bucharest'), 'fara drept de rezervare', 'SB403');
    PERFORM pg_temp.expect_error('INSERT INTO users(full_name,email,phone_number,password_hash) VALUES (''x'',''COSMIN.FLOCEA@student.ro'',''1'',''h'')',
                                 'ux_users_email_lower', '23505');
    RAISE NOTICE 'OK T12 profil/rol, rol fara drept de rezervare si email duplicat (case-insensitive) respinse';

    -- ---------- T13: calendar (fotbal 08-23 => 15 sloturi) ----------
    s := (d3 + TIME '10:00') AT TIME ZONE 'Europe/Bucharest';
    SELECT count(*) INTO v_n FROM get_available_slots(f_foot, d3);
    IF v_n <> 15 THEN RAISE EXCEPTION 'T13 asteptam 15 sloturi (08-23), am primit %', v_n; END IF;
    IF (SELECT is_free FROM get_available_slots(f_foot, d3) WHERE slot_start = s) THEN RAISE EXCEPTION 'T13 slotul 10:00 e ocupat (T2)'; END IF;
    RAISE NOTICE 'OK T13 get_available_slots: 15 sloturi/zi, cele rezervate apar ca ocupate';

    -- ---------- T14: pret detaliat: rol + reducere "rezerva din timp" (bazin 25 RON/loc/ora) ----------
    SELECT * INTO rec FROM fn_price_breakdown(u_stud, f_pool, sp, sp + INTERVAL '1 hour', 1, sp - INTERVAL '1 day');
    IF rec.price_base <> 25.00 OR rec.price_total <> 12.50 OR rec.price_discount <> 12.50 OR rec.early_discount_pct <> 0 THEN
        RAISE EXCEPTION 'T14 student fara early: %', rec;
    END IF;
    SELECT * INTO rec FROM fn_price_breakdown(u_stud, f_pool, sp, sp + INTERVAL '1 hour', 1, sp - INTERVAL '5 days');
    IF rec.price_total <> 11.25 OR rec.price_discount <> 13.75 OR rec.early_discount_pct <> 10 THEN        -- 25 * 0.5 * 0.9
        RAISE EXCEPTION 'T14 student cu early: %', rec;
    END IF;
    SELECT * INTO rec FROM fn_price_breakdown(u_amat, f_pool, sp, sp + INTERVAL '1 hour', 3, sp - INTERVAL '1 day');
    IF rec.price_base <> 75.00 OR rec.price_total <> 75.00 THEN RAISE EXCEPTION 'T14 amator 3 locuri: %', rec; END IF;
    RAISE NOTICE 'OK T14 pret: student 12.50, cu rezervare din timp 11.25, amator 3 locuri 75';

    -- ---------- T15: facilitate pe locuri (bazin 10 locuri), zile inchise ----------
    b  := create_booking(u_stud,  f_pool, sp, sp + INTERVAL '1 hour', 4);
    b2 := create_booking(u_stud2, f_pool, sp, sp + INTERVAL '1 hour', 6);                    -- 4 + 6 = 10 locuri => OK
    IF (SELECT base_amount FROM bookings WHERE booking_id = b) <> 100.00 THEN RAISE EXCEPTION 'T15 pret 4 locuri'; END IF;
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L,1)', u_prof, f_pool, sp, sp + INTERVAL '1 hour'),
                                 'Locuri insuficiente', 'SB409');
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L,11)', u_amat, f_pool, sp, sp + INTERVAL '1 hour'),
                                 'maximum 10 locuri', 'SB400');
    SELECT * INTO rec FROM get_available_slots(f_pool, wd, u_stud) WHERE slot_start = sp;
    IF rec.seats_left <> 0 OR rec.is_free OR rec.capacity <> 10 OR NOT rec.overlaps_own_booking THEN RAISE EXCEPTION 'T15 slot plin: %', rec; END IF;
    SELECT * INTO rec FROM get_available_slots(f_pool, wd, u_stud) WHERE slot_start = sp + INTERVAL '1 hour';
    IF rec.seats_left <> 10 OR NOT rec.is_free OR rec.overlaps_own_booking THEN RAISE EXCEPTION 'T15 slot liber: %', rec; END IF;
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_amat, f_pool,
        (sat + TIME '10:00') AT TIME ZONE 'Europe/Bucharest', (sat + TIME '11:00') AT TIME ZONE 'Europe/Bucharest'),
        'nu functioneaza in aceasta zi', 'SB400');
    IF (SELECT count(*) FROM get_available_slots(f_pool, sat)) <> 0 THEN RAISE EXCEPTION 'T15 sambata trebuia sa nu aiba sloturi'; END IF;
    PERFORM cancel_booking(b2, u_stud2);                                                      -- se elibereaza 6 locuri
    IF (SELECT seats_left FROM get_available_slots(f_pool, wd) WHERE slot_start = sp) <> 6 THEN RAISE EXCEPTION 'T15 locuri dupa anulare'; END IF;
    RAISE NOTICE 'OK T15 bazin: 4+6 locuri ocupa 10/10, al 11-lea loc respins (SB409), sambata inchis, anularea elibereaza locurile';

    -- ---------- T16: un utilizator nu poate fi in doua locuri deodata (sauna + bazin) ----------
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_stud, f_sauna, sp, sp + INTERVAL '30 minutes'),
                                 'ex_bookings_user_no_overlap', '23P01');                     -- u_stud are bazin 15:00-16:00
    s := (d3 + TIME '09:00') AT TIME ZONE 'Europe/Bucharest';
    PERFORM create_booking(u_prof, f_foot, s, s + INTERVAL '1 hour');
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_prof, f_tenis, s, s + INTERVAL '1 hour'),
                                 'ex_bookings_user_no_overlap', '23P01');
    RAISE NOTICE 'OK T16 suprapunerea rezervarilor aceluiasi utilizator (sauna + bazin) e respinsa';

    -- ---------- T17: grila de sloturi (sauna: 30 min) ----------
    sp := (wd + TIME '08:15') AT TIME ZONE 'Europe/Bucharest';
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_stud2, f_sauna, sp, sp + INTERVAL '30 minutes'),
                                 'sloturile de 30 minute', 'SB400');                          -- start nealiniat
    sp := (wd + TIME '08:00') AT TIME ZONE 'Europe/Bucharest';
    PERFORM pg_temp.expect_error(format('SELECT create_booking(%s,%s,%L,%L)', u_stud2, f_sauna, sp, sp + INTERVAL '45 minutes'),
                                 'sloturile de 30 minute', 'SB400');                          -- durata nealiniata
    sp := (wd + TIME '08:30') AT TIME ZONE 'Europe/Bucharest';
    PERFORM create_booking(u_stud2, f_sauna, sp, sp + INTERVAL '30 minutes');
    SELECT count(*) INTO v_n FROM get_available_slots(f_sauna, wd);
    IF v_n <> 26 THEN RAISE EXCEPTION 'T17 sauna 08-21 la 30 min => 26 sloturi, am primit %', v_n; END IF;
    IF fn_calculate_price(u_stud2, f_sauna, sp, sp + INTERVAL '30 minutes') <> 10.00 THEN RAISE EXCEPTION 'T17 pret sauna student'; END IF;
    RAISE NOTICE 'OK T17 sauna: sloturi de 30 min (26/zi), nealiniat respins, student 10 RON / slot';

    -- ---------- T18: inregistrare cu campuri minime (ca in ecranul "Creare cont") ----------
    new_u := register_user('Ana Popescu', 'ana.popescu@stud.univ.ro', NULL, '$2b$10$HASH');
    IF (SELECT count(*) FROM student_profiles WHERE user_id = new_u AND faculty IS NULL AND matricol_number IS NULL) <> 1 THEN
        RAISE EXCEPTION 'T18 profil student';
    END IF;
    SELECT * INTO rec FROM users WHERE user_id = new_u;
    IF rec.preferred_language <> 'ro' OR rec.preferred_currency <> 'RON' OR rec.reminder_minutes_before <> 60 OR rec.dark_mode THEN
        RAISE EXCEPTION 'T18 setari implicite';
    END IF;
    PERFORM register_user('Alt Student', 'alt.student@stud.univ.ro', NULL, '$2b$10$HASH');      -- 2 studenti fara matricol: permis
    new_u := register_user('Prof Nou', 'prof.nou@univ.ro', '0700000000', '$2b$10$HASH', 'PROFESSOR');
    new_u := register_user('Amator Nou', 'amator.nou@mail.ro', NULL, '$2b$10$HASH', 'AMATEUR');
    PERFORM pg_temp.expect_error('SELECT register_user(''Hacker'',''h@x.ro'',NULL,''h'',''ADMIN'')', 'doar de administrator', 'SB403');
    PERFORM pg_temp.expect_error('SELECT register_user(''Ana 2'',''ANA.POPESCU@stud.univ.ro'',NULL,''h'')', 'ux_users_email_lower', '23505');
    UPDATE users SET preferred_language = 'en', preferred_currency = 'EUR', dark_mode = TRUE, reminder_minutes_before = 120 WHERE user_id = new_u;
    PERFORM pg_temp.expect_error(format('UPDATE users SET preferred_language = ''fr'' WHERE user_id = %s', new_u), 'preferred_language');
    RAISE NOTICE 'OK T18 register_user: doar nume/email/parola, setari implicite ro/RON/60 min, rol ADMIN respins, setari validate';

    -- ---------- T19: plata prin procesator extern (PaymentIntent + webhook idempotent) ----------
    s := (d3 + TIME '12:00') AT TIME ZONE 'Europe/Bucharest';
    b := create_booking(u_amat, f_tenis, s, s + INTERVAL '1 hour');                          -- 40 RON
    PERFORM initiate_payment(b, 'CARD_ONLINE', 'pi_test_1');
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'PENDING_PAYMENT' THEN RAISE EXCEPTION 'T19 status'; END IF;
    IF (SELECT amount FROM payments WHERE transaction_ref = 'pi_test_1') <> 40.00 THEN RAISE EXCEPTION 'T19 suma'; END IF;
    PERFORM complete_payment('pi_test_1', TRUE);
    PERFORM complete_payment('pi_test_1', TRUE);                                              -- webhook repetat: fara eroare
    IF (SELECT status FROM bookings WHERE booking_id = b) <> 'CONFIRMED' THEN RAISE EXCEPTION 'T19 confirmat'; END IF;
    PERFORM pg_temp.expect_error('SELECT complete_payment(''pi_inexistent'', true)', 'nu exista', 'SB404');

    s := (d3 + TIME '14:00') AT TIME ZONE 'Europe/Bucharest';
    b2 := create_booking(u_amat, f_tenis, s, s + INTERVAL '1 hour');
    PERFORM initiate_payment(b2, 'CARD_ONLINE', 'pi_a');
    PERFORM initiate_payment(b2, 'CARD_ONLINE', 'pi_b');                                      -- "Reincearca plata": pi_a devine FAILED
    IF (SELECT payment_status FROM payments WHERE transaction_ref = 'pi_a') <> 'FAILED'
       OR (SELECT payment_status FROM payments WHERE transaction_ref = 'pi_b') <> 'PENDING' THEN RAISE EXCEPTION 'T19 retry'; END IF;
    PERFORM cancel_booking(b2, u_amat);                                                       -- utilizatorul alege "Anuleaza / Inapoi"
    IF (SELECT payment_status FROM payments WHERE transaction_ref = 'pi_b') <> 'FAILED' THEN RAISE EXCEPTION 'T19 pi_b dupa anulare'; END IF;
    PERFORM pg_temp.expect_error('SELECT complete_payment(''pi_b'', true)', 'deja in starea', 'SB409');
    RAISE NOTICE 'OK T19 initiate_payment + complete_payment idempotent, retry marcheaza tranzactia veche FAILED, anularea inchide plata PENDING';

    -- ---------- T20: remindere (1h inainte, o singura data) ----------
    s := (d3 + TIME '22:00') AT TIME ZONE 'Europe/Bucharest';
    b := create_booking(u_prof, f_foot, s, s + INTERVAL '1 hour');
    PERFORM register_payment(b, 'CARD_ONLINE', 'TXN_TEST_T20', TRUE);
    IF (SELECT count(*) FROM claim_due_reminders(s - INTERVAL '3 hours') WHERE booking_id = b) <> 0 THEN RAISE EXCEPTION 'T20 prea devreme'; END IF;
    IF (SELECT count(*) FROM claim_due_reminders(s - INTERVAL '30 minutes') WHERE booking_id = b) <> 1 THEN RAISE EXCEPTION 'T20 trebuia trimis'; END IF;
    IF (SELECT count(*) FROM claim_due_reminders(s - INTERVAL '20 minutes') WHERE booking_id = b) <> 0 THEN RAISE EXCEPTION 'T20 dublura'; END IF;
    s := (d3 + TIME '21:00') AT TIME ZONE 'Europe/Bucharest';
    b2 := create_booking(u_amat, f_foot, s, s + INTERVAL '1 hour', 1, FALSE);                 -- reminder dezactivat din ecranul 07
    PERFORM register_payment(b2, 'CARD_ONLINE', 'TXN_TEST_T20B', TRUE);
    IF (SELECT count(*) FROM claim_due_reminders(s - INTERVAL '30 minutes') WHERE booking_id = b2) <> 0 THEN RAISE EXCEPTION 'T20 reminder dezactivat'; END IF;
    RAISE NOTICE 'OK T20 reminder: nu inainte de fereastra, o singura data, respecta comutatorul per rezervare';

    -- ---------- T21: view-uri pentru ecranele din Figma ----------
    SELECT * INTO rec FROM v_booking_details WHERE booking_id = b;
    IF rec.booking_code !~ '^SC-[0-9]{6}-[0-9]{3,}$' OR rec.qr_payload IS NULL OR rec.user_id <> u_prof
       OR rec.last_payment_status <> 'SUCCESS' OR NOT rec.is_upcoming THEN RAISE EXCEPTION 'T21 v_booking_details: %', rec; END IF;
    b3 := create_booking(u_amat, f_foot, (d3 + TIME '08:00') AT TIME ZONE 'Europe/Bucharest', (d3 + TIME '09:00') AT TIME ZONE 'Europe/Bucharest');   -- INITIATED: fara QR
    IF (SELECT qr_payload FROM v_booking_details WHERE booking_id = b3) IS NOT NULL THEN RAISE EXCEPTION 'T21 QR inainte de plata'; END IF;
    IF (SELECT count(*) FROM v_facility_catalog) <> 5 THEN RAISE EXCEPTION 'T21 catalog'; END IF;
    SELECT * INTO rec FROM v_facility_catalog WHERE sport_type = 'Saună';
    IF rec.price_per_slot <> 20.00 OR rec.price_per_slot_eur <> 4.00 OR rec.category <> 'Relaxare' THEN RAISE EXCEPTION 'T21 sauna: %', rec; END IF;
    IF fn_ron_to_eur(35) <> 7.00 THEN RAISE EXCEPTION 'T21 curs'; END IF;
    RAISE NOTICE 'OK T21 view-uri: cod rezervare SC-DDMMYY-NNN, QR ascuns pana la plata, catalog cu pret/slot si EUR';

    RAISE NOTICE '=== TOATE TESTELE AU TRECUT ===';
END $$;

ROLLBACK;
