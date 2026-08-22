# Railway deploy — Frappe CRM

Single container: nginx (public `$PORT`) → gunicorn (8000) + socketio (9000), plus an
RQ worker and the scheduler, all under honcho. MariaDB and Redis are separate Railway
services.

## Why one container

Railway attaches a volume to exactly one service. Frappe's `sites/` directory holds
`site_config.json`, uploaded files and built assets, and the web process, the workers,
the scheduler and socketio all read and write it. Splitting them into separate Railway
services would give each its own volume — the site would exist for one of them only.

The trade-off: no horizontal scaling, and a short downtime on every deploy.

## Services to create in the Railway project

| Service | Source | Notes |
|---|---|---|
| `crm24` | this repo | volume mounted at `/home/frappe/frappe-bench/sites` |
| MariaDB | Railway template | **MariaDB, not MySQL** — Frappe does not support MySQL 8/9 |
| Redis | Railway template | one instance; db 0 = cache, db 1 = queue |

## Environment variables on the app service

| Variable | Value | Required |
|---|---|---|
| `DB_HOST` | `${{MariaDB.MYSQLHOST}}` | yes (falls back to `MYSQLHOST`) |
| `DB_PORT` | `${{MariaDB.MYSQLPORT}}` | defaults to 3306 |
| `DB_ROOT_PASSWORD` | `${{MariaDB.MYSQL_ROOT_PASSWORD}}` | yes — `bench new-site` creates the database and its user |
| `REDIS_URL` | `${{Redis.REDIS_URL}}` | yes |
| `SITE_NAME` | e.g. `crm24.up.railway.app` | defaults to `crm.localhost` |
| `ADMIN_PASSWORD` | Administrator's password | defaults to `admin` — set it |
| `GUNICORN_WORKERS` | `2` | optional |
| `MAX_UPLOAD_SIZE` | `50m` | optional |

`SITE_NAME` is only a name on disk. nginx sends it as `X-Frappe-Site-Name` on every
request, so the site answers on whatever domain Railway assigns.

## First boot

The volume starts empty, so the entrypoint seeds it from a copy baked into the image,
then runs `bench new-site … --install-app crm`. That takes a few minutes; the health
check allows 300s. Subsequent deploys run `bench migrate` instead, and always refresh
`sites/assets` from the new image.

## Known gaps

- **No `wkhtmltopdf`** — PDF printing will fail. Add the package to the Dockerfile if
  print formats are needed.
- **No email inbound** — the scheduler polls, but incoming mail needs an Email Account
  configured in the app.
- **Backups are not automatic.** `bench --site <site> backup` writes into the volume;
  copy them off with `railway run` or set up S3 backups in Frappe.
