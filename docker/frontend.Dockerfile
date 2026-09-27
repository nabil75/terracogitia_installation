# syntax=docker/dockerfile:1.7
# Terra-Cogitia Front-End (Angular SPA served by unprivileged nginx on :8200).
#
# Build context : ../terracogitia_frontend
# Named context : installation = Installation/docker   (nginx config + runtime env script)
# The API URL is NOT baked in: assets/env.js is generated at container start from API_BASE_URL,
# so the same image runs locally and on Hetzner.

FROM node:22-alpine AS build
WORKDIR /src
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
COPY . .
RUN npx ng build --configuration production
# Strip CR: a Windows checkout (git core.autocrlf=true) gives the script CRLF endings, and
# "#!/bin/sh\r" makes the nginx entrypoint fail with "40-cogitia-env.sh: not found".
COPY --from=installation frontend-env.sh /tmp/40-cogitia-env.sh
RUN sed -i 's/\r$//' /tmp/40-cogitia-env.sh

FROM nginxinc/nginx-unprivileged:1.27-alpine
COPY --from=installation frontend-nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build --chmod=755 /tmp/40-cogitia-env.sh /docker-entrypoint.d/40-cogitia-env.sh
COPY --from=build --chown=nginx:nginx /src/dist/terra-cogitia/browser /usr/share/nginx/html
EXPOSE 8200
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD wget -q --spider http://127.0.0.1:8200/healthz || exit 1
