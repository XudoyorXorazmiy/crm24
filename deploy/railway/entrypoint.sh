#!/usr/bin/env bash
# Boots the Frappe CRM container on Railway: reconciles config with the environment,
# creates or migrates the site, then hands off to honcho.
set -euo pipefail

BENCH=/home/frappe/frappe-bench
TEMPLATE=/home/frappe/sites-template
cd "$BENCH"

# ── Environment ──────────────────────────────────────────────────────────────
# Railway's database and Redis plugins inject their own variable names; accept
# those as fallbacks so the service works with nothing but the plugin references.
DB_HOST="${DB_HOST:-${MYSQLHOST:-}}"
DB_PORT="${DB_PORT:-${MYSQLPORT:-3306}}"
DB_ROOT_USER="${DB_ROOT_USER:-root}"
DB_ROOT_PASSWORD="${DB_ROOT_PASSWORD:-${MYSQL_ROOT_PASSWORD:-${MARIADB_ROOT_PASSWORD:-}}}"

REDIS_URL="${REDIS_URL:-}"
if [ -z "$REDIS_URL" ] && [ -n "${REDISHOST:-}" ]; then
  if [ -n "${REDISPASSWORD:-}" ]; then
    REDIS_URL="redis://default:${REDISPASSWORD}@${REDISHOST}:${REDISPORT:-6379}"
  else
    REDIS_URL="redis://${REDISHOST}:${REDISPORT:-6379}"
  fi
fi

SITE_NAME="${SITE_NAME:-crm.localhost}"
ADMIN_PASSWORD="${ADMIN_PASSWORD:-admin}"
PORT="${PORT:-8080}"
MAX_UPLOAD_SIZE="${MAX_UPLOAD_SIZE:-50m}"
GUNICORN_WORKERS="${GUNICORN_WORKERS:-2}"
export PORT SITE_NAME MAX_UPLOAD_SIZE GUNICORN_WORKERS

missing=()
[ -n "$DB_HOST" ] || missing+=("DB_HOST (or MYSQLHOST)")
[ -n "$DB_ROOT_PASSWORD" ] || missing+=("DB_ROOT_PASSWORD (or MYSQL_ROOT_PASSWORD)")
[ -n "$REDIS_URL" ] || missing+=("REDIS_URL (or REDISHOST)")
if [ ${#missing[@]} -gt 0 ]; then
  echo "FATAL: missing required environment variables:" >&2
  printf '  - %s\n' "${missing[@]}" >&2
  exit 1
fi

# ── sites/ volume ────────────────────────────────────────────────────────────
# The Railway volume mounts over sites/, so on first boot it is empty and has to be
# seeded from the copy baked into the image.
if [ ! -f "$BENCH/sites/apps.txt" ]; then
  echo "==> Seeding empty sites volume from image template"
  cp -a "$TEMPLATE/." "$BENCH/sites/"
fi

# Assets are rebuilt into the image on every deploy but the volume still holds the
# previous deploy's copy, so refresh them unconditionally.
echo "==> Refreshing sites/assets from image"
rm -rf "$BENCH/sites/assets"
cp -a "$TEMPLATE/assets" "$BENCH/sites/assets"
cp -a "$TEMPLATE/apps.txt" "$BENCH/sites/apps.txt"

# ── Bench config ─────────────────────────────────────────────────────────────
echo "==> Writing common_site_config.json"
export _DB_HOST="$DB_HOST" _DB_PORT="$DB_PORT" _REDIS_URL="$REDIS_URL"
python3 - <<PYEOF
import json, os, pathlib

path = pathlib.Path("$BENCH/sites/common_site_config.json")
config = json.loads(path.read_text()) if path.exists() else {}
config.update({
    "db_host": os.environ.get("_DB_HOST"),
    "db_port": int(os.environ.get("_DB_PORT")),
    # One Redis instance serves both roles, separated by database index.
    "redis_cache": os.environ.get("_REDIS_URL") + "/0",
    "redis_queue": os.environ.get("_REDIS_URL") + "/1",
    "redis_socketio": os.environ.get("_REDIS_URL") + "/1",
    "socketio_port": 9000,
    "webserver_port": 8000,
    "background_workers": 1,
    "gunicorn_workers": int(os.environ.get("GUNICORN_WORKERS")),
    "developer_mode": 0,
    "serve_default_site": True,
    "maintenance_mode": 0,
    "pause_scheduler": 0,
})
path.write_text(json.dumps(config, indent=1))
PYEOF

# ── Wait for the database ────────────────────────────────────────────────────
echo "==> Waiting for MariaDB at ${DB_HOST}:${DB_PORT}"
for attempt in $(seq 1 60); do
  if mysqladmin ping -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ROOT_USER" \
       -p"$DB_ROOT_PASSWORD" --protocol=TCP --silent 2>/dev/null; then
    echo "    database is up"
    break
  fi
  if [ "$attempt" -eq 60 ]; then
    echo "FATAL: database unreachable after 60 attempts" >&2
    exit 1
  fi
  sleep 2
done

# ── Site ─────────────────────────────────────────────────────────────────────
if [ ! -f "$BENCH/sites/$SITE_NAME/site_config.json" ]; then
  echo "==> Creating site $SITE_NAME"
  bench new-site "$SITE_NAME" \
    --db-root-username "$DB_ROOT_USER" \
    --db-root-password "$DB_ROOT_PASSWORD" \
    --admin-password "$ADMIN_PASSWORD" \
    --mariadb-user-host-login-scope='%' \
    --install-app crm \
    --set-default
else
  echo "==> Migrating existing site $SITE_NAME"
  bench --site "$SITE_NAME" migrate
fi

echo "$SITE_NAME" > "$BENCH/sites/currentsite.txt"

# ── nginx ────────────────────────────────────────────────────────────────────
mkdir -p /tmp/nginx-body /tmp/nginx-proxy /tmp/nginx-fastcgi /tmp/nginx-uwsgi /tmp/nginx-scgi
envsubst '${PORT} ${SITE_NAME} ${MAX_UPLOAD_SIZE}' \
  < /home/frappe/nginx.conf.template > /home/frappe/nginx.conf
nginx -c /home/frappe/nginx.conf -t

echo "==> Starting services on port ${PORT}"
# -d pins the children's working directory to the bench root; honcho would
# otherwise use the Procfile's own directory and every relative path would break.
exec honcho -f /home/frappe/Procfile -d "$BENCH" start
