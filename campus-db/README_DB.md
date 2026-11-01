# Campus Sports Booking – Baza de date (PostgreSQL 16) · v2.1

Echipa 3BITS · Laborator 5 (task 9.7)

## Fisiere
| Fisier | Rol |
|---|---|
| `schema_campus_sports_v2.sql` | Tabele, constrangeri, functii, triggere, view-uri, date de test |
| `test_scenarios.sql` | 21 teste automate (se anuleaza la final cu ROLLBACK, nu modifica datele) |
| `docker-compose.yml` + `.env.example` | Baza locala + Adminer (client web). Pe unele sisteme fisierul apare ca `env.example` |
| `roles_team_access.sql` | Roluri `campus_app` / `campus_readonly` – doar pentru o baza comuna |

## Pornire rapida (fiecare coleg, pe calculatorul lui)
1. Instaleaza Docker Desktop.
2. `cp .env.example .env` (Windows: `copy .env.example .env`) si schimba `DB_PASSWORD`.
3. `docker compose up -d` → baza `campus_sports` este creata si populata automat.
4. Conectare: `localhost:5432` (DBeaver/pgAdmin) sau http://localhost:8080 (Adminer; server = `db`).
5. Teste: `docker compose cp test_scenarios.sql db:/tmp/t.sql` apoi
   `docker compose exec db psql -U campus_admin -d campus_sports -v ON_ERROR_STOP=1 -f /tmp/t.sql`

**Dupa orice schimbare a schemei** (inclusiv trecerea de la v2 la v2.1): `docker compose down -v && docker compose up -d`
(scriptul din `docker-entrypoint-initdb.d` ruleaza doar cand volumul este gol).

## Contractul API ↔ baza de date
| Endpoint | Apel in baza de date |
|---|---|
| `POST /auth/register` | `register_user(...)` – doar nume, email, parola hash-uita sunt obligatorii; rolurile `STUDENT/PROFESSOR/AMATEUR` |
| `POST /auth/login` | `SELECT ... FROM users WHERE lower(email) = lower($1)`; bcrypt se verifica in backend |
| `GET/PATCH /users/me` | coloanele `preferred_language`, `preferred_currency`, `dark_mode`, `reminder_minutes_before` din `users` |
| `GET /facilities?sportType=&category=` | `v_facility_catalog` (pret / slot, EUR, program, zile, reducere "rezerva din timp") |
| `GET /facilities/{id}/availability?date=` | `get_available_slots(id, date, userId)` → `seats_left`, `capacity`, `is_free`, `overlaps_own_booking` |
| `GET /tariffs/calculate` | `fn_price_breakdown(user, facility, start, end, seats)` → baza, reducere, total, % rol, % early |
| `POST /bookings` | `create_booking(user, facility, start, end, seats, reminder)` + `INSERT INTO booking_equipment (booking_id, equipment_id, quantity)`; **raspunsul 201 nu contine QR** |
| `POST /bookings/{id}/pay` | `initiate_payment(id, method, ref)` (sau `confirm_free_booking(id)` daca totalul este 0) |
| `POST /payments/webhook` | `complete_payment(ref, success)` – idempotent; la SB409 backend-ul ramburseaza tranzactia |
| `POST /bookings/{id}/cancel` | `cancel_booking(id, userId)` |
| `GET /bookings/my-bookings` | `SELECT * FROM v_booking_details WHERE user_id = $1` (`is_upcoming` separa "Viitoare" de "Istoric") |
| `POST /qr/validate` | `SELECT * FROM validate_qr(payload, receptionistId)` → nume, rol, facilitate, interval |
| node-cron, la 1 minut | `expire_stale_bookings()` si `claim_due_reminders()` (returneaza e-mailurile de trimis) |

Simulare plata (MVP "Demonstrativ"): `register_payment(id, 'CARD_ONLINE', 'TXN_x', true/false)`.

## Coduri de eroare pentru backend (`err.original.code`)
| SQLSTATE | Inseamna | HTTP |
|---|---|---|
| `SB400` | regula de business incalcata (in trecut, in afara programului, <24h la anulare, ...) | 400 |
| `SB403` | interzis (alt utilizator, nu esti la receptie, QR deja folosit / invalidat / in afara intervalului) | 403 |
| `SB404` | inexistent (cod QR necunoscut, rezervare, tranzactie) | 404 |
| `SB409` | conflict (locuri insuficiente, stoc, plata nu mai e posibila) | 409 |
| `23P01` | suprapunere pe acelasi teren sau a aceluiasi utilizator | 409 |
| `23505` | email / matricol deja existent | 400 / 409 |

## Reguli de business implementate in baza de date
- Terenuri (`EXCLUSIVE`): o singura rezervare activa pe interval. Bazin, saună, fitness (`SHARED`): rezervare pe locuri, pana la `capacity`.
- Un utilizator nu poate avea doua rezervari active suprapuse (ex. saună + bazin).
- Rezervarea respecta grila facilitatii (`slot_minutes`: bazin 60, saună 30), programul si zilele de functionare.
- Rezervare noua = `INITIATED`, blocata 5 minute. Plata esuata o lasa in `PENDING_PAYMENT` (se poate reincerca); dupa 5 minute job-ul o anuleaza.
- Codul QR apare abia dupa plata (`CONFIRMED`); se invalideaza la anulare. Acces: de la 15 minute inainte de start pana la final.
- Anulare: gratuita cu minim 24h inainte; echipamentul revine in stoc.
- Pret: reducere de rol (Student 50%, Profesor 30%) si, unde exista, reducerea "rezerva din timp" (bazin: 10% cu 3 zile inainte), aplicate succesiv.

## Reguli de echipa
- Schema se schimba DOAR in `schema_campus_sports_v2.sql` + pull request; dupa schimbare: reset local + teste.
- `.env`, parole si string-uri de conexiune NU se pun in Git.
- Parolele din seed sunt placeholder; utilizatorii reali se creeaza prin `register_user` cu hash bcrypt.
- Scriptul face `DROP TABLE` pe tot: se foloseste doar pe baze locale / de test.
