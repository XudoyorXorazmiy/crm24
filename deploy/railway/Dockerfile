# Frappe CRM — single-container image for Railway.
#
# Railway attaches a volume to exactly one service, but Frappe's `sites/` directory
# (site_config.json, uploaded files, assets) must be shared by the web server, the
# background workers, the scheduler and socketio. So all of them run here, side by
# side under honcho, behind an nginx that fronts Railway's single exposed $PORT.
#
# External dependencies (Railway plugins, wired via env vars):
#   - MariaDB  -> DB_HOST / DB_PORT / DB_ROOT_PASSWORD
#   - Redis    -> REDIS_URL
FROM python:3.14-slim-bookworm

ENV PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive \
    PATH="/home/frappe/.local/bin:${PATH}"

# mariadb-client is required by `bench new-site` (it pipes the framework's schema
# through the mysql CLI); libmariadb-dev is what mysqlclient compiles against.
RUN apt-get update && apt-get install -y --no-install-recommends \
      ca-certificates curl wget gnupg git \
      build-essential pkg-config \
      libmariadb-dev mariadb-client \
      libffi-dev libssl-dev libbz2-dev \
      libjpeg-dev zlib1g-dev libwebp-dev libfreetype6-dev \
      nginx gettext-base \
    && curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && npm install -g yarn \
    && rm -rf /var/lib/apt/lists/*

# nginx runs unprivileged as the frappe user, so every path it writes to has to be
# owned by that user — /run and the body/proxy temp dirs included.
RUN useradd -ms /bin/bash frappe \
    && mkdir -p /var/lib/nginx /var/log/nginx /run/nginx \
    && chown -R frappe:frappe /var/lib/nginx /var/log/nginx /run/nginx

RUN pip install --no-cache-dir frappe-bench

USER frappe
WORKDIR /home/frappe

RUN bench init \
      --skip-redis-config-generation \
      --frappe-branch develop \
      --verbose \
      /home/frappe/frappe-bench

WORKDIR /home/frappe/frappe-bench

# bench get-app clones, so the build context needs to be a git repo of its own.
# The directory must be named `crm` — bench derives the app name from it.
COPY --chown=frappe:frappe . /tmp/crm
RUN cd /tmp/crm \
    && rm -rf .git node_modules frontend/node_modules \
    && git init -q \
    && git add -A \
    && git -c user.email=build@localhost -c user.name=build commit -qm "railway build" \
    && cd /home/frappe/frappe-bench \
    && bench get-app /tmp/crm \
    && bench build --production --app crm \
    && rm -rf /tmp/crm /home/frappe/.cache/yarn

# The volume gets mounted over sites/, hiding whatever the image put there. Keep a
# pristine copy so the entrypoint can seed an empty volume on first boot.
RUN cp -a /home/frappe/frappe-bench/sites /home/frappe/sites-template

COPY --chown=frappe:frappe deploy/railway/entrypoint.sh /home/frappe/entrypoint.sh
COPY --chown=frappe:frappe deploy/railway/nginx.conf.template /home/frappe/nginx.conf.template
COPY --chown=frappe:frappe deploy/railway/Procfile /home/frappe/Procfile
RUN chmod +x /home/frappe/entrypoint.sh

CMD ["/home/frappe/entrypoint.sh"]
