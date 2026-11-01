-- =====================================================================
-- ROLURI PENTRU ACCES PARTAJAT (doar daca folositi O BAZA COMUNA, nu docker local)
-- Ruleaza o singura data, ca administrator, conectat la baza campus_sports:
--   psql "<connection string admin>" -v ON_ERROR_STOP=1 -f roles_team_access.sql
-- Inlocuieste parolele cu unele generate (ex: openssl rand -base64 24) si trimite-le
-- colegilor printr-un password manager - NICIODATA in Git sau pe chat.
-- =====================================================================

-- 1) Rol pentru aplicatia backend (Express/Sequelize): poate citi/scrie date si apela functiile,
--    dar NU poate sterge/modifica structura (nu poate DROP TABLE).
CREATE ROLE campus_app LOGIN PASSWORD 'SCHIMBA_PAROLA_APP';
-- 2) Rol de citire pentru colegi (DBeaver/pgAdmin): doar SELECT.
CREATE ROLE campus_readonly LOGIN PASSWORD 'SCHIMBA_PAROLA_READONLY';

DO $$
BEGIN
    EXECUTE format('GRANT CONNECT ON DATABASE %I TO campus_app, campus_readonly', current_database());
END $$;
GRANT USAGE ON SCHEMA public TO campus_app, campus_readonly;

GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES    IN SCHEMA public TO campus_app;
GRANT USAGE, SELECT                  ON ALL SEQUENCES IN SCHEMA public TO campus_app;
GRANT EXECUTE                        ON ALL FUNCTIONS IN SCHEMA public TO campus_app;

GRANT SELECT ON ALL TABLES IN SCHEMA public TO campus_readonly;

-- si pentru obiectele create ulterior de proprietar (migratii noi):
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES    TO campus_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT                  ON SEQUENCES TO campus_app;
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT                         ON TABLES    TO campus_readonly;
