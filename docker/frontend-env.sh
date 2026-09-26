#!/bin/sh
# Generates assets/env.js from API_BASE_URL (run by the nginx entrypoint before nginx starts).
# The browser loads this file before the Angular bundle; ApiService reads window.__TC_CONFIG__.
set -eu

: "${API_BASE_URL:?API_BASE_URL is required}"
case "$API_BASE_URL" in
    *'"'* | *'\'* | *' '*) echo "cogitia-env: API_BASE_URL contains invalid characters" >&2; exit 1 ;;
esac

api_url="${API_BASE_URL%/}"
printf 'window.__TC_CONFIG__ = { apiBaseUrl: "%s" };\n' "$api_url" > /usr/share/nginx/html/assets/env.js
echo "cogitia-env: apiBaseUrl=$api_url"
