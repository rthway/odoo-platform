# syntax=docker/dockerfile:1.7
# ===========================================================================
# Odoo application image
# ===========================================================================
# Built ONCE per commit, scanned once, then promoted unchanged through
# DEV -> QA -> PROD. The image carries no environment-specific data: every
# difference between environments arrives at runtime through the .env file.
# ===========================================================================

ARG ODOO_VERSION=18.0-20260817

FROM odoo:${ODOO_VERSION}

# Re-declare after FROM: ARGs before FROM are out of scope in the build stage.
ARG ODOO_VERSION
ARG BUILD_DATE
ARG VCS_REF
ARG VERSION

LABEL org.opencontainers.image.title="odoo-platform" \
      org.opencontainers.image.description="Production Odoo Community Edition platform" \
      org.opencontainers.image.vendor="Nyaya Health Nepal" \
      org.opencontainers.image.licenses="LGPL-3.0-or-later" \
      org.opencontainers.image.source="https://github.com/rthway/odoo-platform" \
      org.opencontainers.image.base.name="docker.io/library/odoo:${ODOO_VERSION}" \
      org.opencontainers.image.created="${BUILD_DATE}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.version="${VERSION}"

# Root only for the install steps; we drop back to odoo before CMD.
USER root

# Build tooling lives only in this layer's lifetime. gettext-base gives us
# envsubst, which renders odoo.conf from its template at container start.
COPY requirements.txt /tmp/requirements.txt
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
        gettext-base \
        postgresql-client \
        curl \
    ; \
    if grep -qvE '^\s*(#|$)' /tmp/requirements.txt; then \
        pip3 install --no-cache-dir --break-system-packages -r /tmp/requirements.txt; \
    fi; \
    rm -f /tmp/requirements.txt; \
    apt-get purge -y --auto-remove; \
    rm -rf /var/lib/apt/lists/*

# Custom addons. Copied late so dependency layers stay cached across changes.
COPY --chown=odoo:odoo addons /mnt/extra-addons

COPY --chown=root:root docker/odoo/entrypoint.sh   /usr/local/bin/platform-entrypoint.sh
COPY --chown=root:root docker/odoo/healthcheck.sh  /usr/local/bin/platform-healthcheck.sh
COPY --chown=root:root config/odoo/odoo.conf.tmpl  /etc/odoo/odoo.conf.tmpl

RUN set -eux; \
    chmod 0755 /usr/local/bin/platform-entrypoint.sh /usr/local/bin/platform-healthcheck.sh; \
    chmod 0644 /etc/odoo/odoo.conf.tmpl; \
    install -d -o odoo -g odoo -m 0750 /etc/odoo /var/lib/odoo /mnt/extra-addons

# Never run the application as root.
USER odoo

EXPOSE 8069 8072

# Docker's own healthcheck. The deploy pipeline does NOT trust this alone;
# scripts/healthcheck.sh re-verifies from outside the container.
HEALTHCHECK --interval=30s --timeout=10s --start-period=90s --retries=3 \
    CMD ["/usr/local/bin/platform-healthcheck.sh"]

ENTRYPOINT ["/usr/local/bin/platform-entrypoint.sh"]
CMD ["odoo"]
