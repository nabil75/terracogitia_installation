# syntax=docker/dockerfile:1.7
# Terra-Cogitia Database (PostgreSQL 17, matching the pg_dump 17 seed files).
#
# Build context : ../terracogitia_backend/data   (schema.sql + data.sql)
# The seed runs ONLY when the data volume is empty (first start); existing data is never overwritten.
# The Back-End then applies its own idempotent migrations at startup (database.py).

FROM postgres:17-alpine
COPY --chmod=644 schema.sql /docker-entrypoint-initdb.d/01-schema.sql
COPY --chmod=644 data.sql   /docker-entrypoint-initdb.d/02-data.sql
EXPOSE 5432
HEALTHCHECK --interval=10s --timeout=5s --start-period=120s --retries=6 \
    CMD pg_isready -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" || exit 1
