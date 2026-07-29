# Talistra website

The public landing page, privacy policy, feedback API, and protected feedback
dashboard live here. The server uses only the Python standard library and
stores messages in SQLite.

## Required environment variables

- `TALISTRA_ADMIN_PASSWORD` — administrator password, at least 14 characters.
- `TALISTRA_SESSION_SECRET` — random session-signing secret, at least 32 characters.
- `TALISTRA_ADMIN_PATH` — unlisted dashboard path without slashes.
- `TALISTRA_DB` — SQLite path, `/var/lib/talistra/feedback.sqlite3` in production.
- `TALISTRA_PORT` — local HTTP port, `8017` by default.

The service binds only to `127.0.0.1`; Nginx terminates HTTPS and proxies
requests to it.
