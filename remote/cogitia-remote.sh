#!/usr/bin/env bash
# =============================================================================
# cogitia-remote.sh -- Terra-Cogitia server-side operations (Hetzner).
#
# Uploaded to <deploy_dir> and driven over SSH by deploy-all.ps1, clean-all.ps1
# and renew-certificates.ps1. All names come from cogitia.env (generated from
# cogitia-registry.json). Scope is strictly Terra-Cogitia: resources are
# addressed by exact name or by the image label -- never a global prune.
#
# Usage:
#   cogitia-remote.sh deploy [--clean-tar]
#   cogitia-remote.sh clean  [--purge-data] [--remove-nginx] [--keep-images]
#   cogitia-remote.sh apply-secrets                 # recreate the Back-End with secrets/backend.env
#   cogitia-remote.sh status
#   cogitia-remote.sh backup
#   cogitia-remote.sh nginx                         # install/refresh the host vhost
#   cogitia-remote.sh cert-status
#   cogitia-remote.sh cert-issue <email> [--dry-run]
#   cogitia-remote.sh cert-renew [--dry-run] [--force]
#
# Exit codes: 0 ok, 1 failure, 2 usage error, 3 skipped (e.g. nginx not installed)
# =============================================================================

set -euo pipefail

DEPLOY_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$DEPLOY_DIR/cogitia.env"
COMPOSE_FILE="$DEPLOY_DIR/docker-compose.yml"
IMAGES_DIR="$DEPLOY_DIR/images"
BACKUP_DIR="$DEPLOY_DIR/backups"
NGINX_TPL_DIR="$DEPLOY_DIR/nginx"
NGINX_SITE_NAME="terra-cogitia.conf"
BACKUP_KEEP=5
HEALTH_TIMEOUT=300

# --- Logging -----------------------------------------------------------------

header() { echo; echo "------------------------------------------------------------"; echo "  $*"; echo "------------------------------------------------------------"; }
log()    { echo "  $*"; }
ok()     { echo "  [OK]   $*"; }
warn()   { echo "  [WARN] $*"; }
die()    { echo "  [FAIL] $*" >&2; exit 1; }

# --- Configuration -----------------------------------------------------------

load_env() {
    [[ -f "$ENV_FILE" ]] || die "Missing $ENV_FILE -- run deploy-all.ps1 first"
    set -a
    # shellcheck disable=SC1090
    . "$ENV_FILE"
    set +a
    local v
    for v in COMPOSE_PROJECT_NAME NETWORK_NAME IMAGE_LABEL \
             DATABASE_IMAGE DATABASE_CONTAINER DATABASE_ALIAS DATABASE_VOLUME \
             BACKEND_IMAGE BACKEND_CONTAINER BACKEND_ALIAS BACKEND_VOLUME BACKEND_PORT BACKEND_HEALTH_PATH BACKEND_DB_CHECK_PATH \
             FRONTEND_IMAGE FRONTEND_CONTAINER FRONTEND_ALIAS FRONTEND_PORT FRONTEND_HEALTH_PATH \
             POSTGRES_DB POSTGRES_USER BIND_ADDRESS API_BASE_URL CORS_ORIGINS; do
        [[ -n "${!v:-}" ]] || die "$v is not set in $ENV_FILE"
    done
    CONTAINERS=("$DATABASE_CONTAINER" "$BACKEND_CONTAINER" "$FRONTEND_CONTAINER")
    IMAGES=("$DATABASE_IMAGE" "$BACKEND_IMAGE" "$FRONTEND_IMAGE")
    VOLUMES=("$DATABASE_VOLUME" "$BACKEND_VOLUME")
}

compose() {
    docker compose -p "$COMPOSE_PROJECT_NAME" --project-directory "$DEPLOY_DIR" \
        --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

container_exists()  { docker container inspect "$1" >/dev/null 2>&1; }
container_running() { [[ "$(docker container inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == "true" ]]; }
network_members()   { docker network inspect -f '{{range .Containers}}{{.Name}} {{end}}' "$NETWORK_NAME" 2>/dev/null; }

require_docker() {
    command -v docker >/dev/null || die "docker is not installed on this server"
    docker info >/dev/null 2>&1 || die "docker daemon is not reachable"
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 plugin ('docker compose') is not installed"
    command -v curl >/dev/null || die "curl is required on the server"
}

# --- Building blocks ----------------------------------------------------------

backup_database() {
    local tag="${1:-predeploy}"
    if ! container_running "$DATABASE_CONTAINER"; then
        log "Backup skipped: $DATABASE_CONTAINER not running (first deployment?)"
        return 0
    fi
    mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
    local file="$BACKUP_DIR/cogitia_${POSTGRES_DB}_${tag}_$(date +%Y%m%d_%H%M%S).dump"
    if docker exec "$DATABASE_CONTAINER" pg_dump -U "$POSTGRES_USER" -d "$POSTGRES_DB" -Fc > "$file"; then
        ok "Database backup: $file ($(stat -c%s "$file") bytes)"
    else
        rm -f "$file"
        die "Database backup failed -- aborting to protect data"
    fi
    # shellcheck disable=SC2012
    ls -1t "$BACKUP_DIR"/cogitia_*.dump 2>/dev/null | tail -n +$((BACKUP_KEEP + 1)) | xargs -r rm -f
}

ensure_network() {
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        ok "Network $NETWORK_NAME already exists"
    else
        docker network create --label "$IMAGE_LABEL" "$NETWORK_NAME" >/dev/null
        ok "Network $NETWORK_NAME created"
    fi
}

load_images() {
    local tar found=0
    for tar in "$IMAGES_DIR"/*.tar; do
        [[ -e "$tar" ]] || continue
        found=1
        log "docker load -i $tar"
        docker load -i "$tar" | sed 's/^/    /'
    done
    if [[ $found -eq 0 ]]; then
        log "No image archives in $IMAGES_DIR -- using images already present"
    fi
    local img
    for img in "${IMAGES[@]}"; do
        docker image inspect "$img" >/dev/null 2>&1 || die "Image $img is not present on the server (transfer it with deploy-all.ps1)"
    done
    ok "Images present: ${IMAGES[*]}"
}

remove_stray_containers() {
    # A container with one of our names but not owned by the compose project would block 'up'.
    local c owner
    for c in "${CONTAINERS[@]}"; do
        container_exists "$c" || continue
        owner="$(docker container inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$c" 2>/dev/null || true)"
        if [[ "$owner" != "$COMPOSE_PROJECT_NAME" ]]; then
            warn "Removing stray container $c (not managed by compose project $COMPOSE_PROJECT_NAME)"
            docker rm -f "$c" >/dev/null
        fi
    done
}

wait_healthy() {
    local deadline=$((SECONDS + HEALTH_TIMEOUT)) c state last=""
    local -a pending
    while :; do
        pending=()
        for c in "${CONTAINERS[@]}"; do
            state="$(docker container inspect -f '{{.State.Status}}/{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$c" 2>/dev/null || echo missing)"
            [[ "$state" == "running/healthy" ]] || pending+=("$c=$state")
        done
        if [[ ${#pending[@]} -eq 0 ]]; then
            ok "All containers healthy: ${CONTAINERS[*]}"
            return 0
        fi
        if [[ "${pending[*]}" != "$last" ]]; then log "waiting: ${pending[*]}"; last="${pending[*]}"; fi
        if (( SECONDS >= deadline )); then
            for c in "${CONTAINERS[@]}"; do
                echo "  --- last log lines: $c"
                docker logs --tail 40 "$c" 2>&1 | sed 's/^/    /' || true
            done
            die "Containers not healthy after ${HEALTH_TIMEOUT}s: ${pending[*]}"
        fi
        sleep 5
    done
}

# --- Verification (from the server itself) -----------------------------------

FAILURES=0
check() {
    local name="$1"; shift
    if "$@" >/dev/null 2>&1; then ok "$name"; else echo "  [FAIL] $name"; FAILURES=$((FAILURES + 1)); fi
}

fe_url() { echo "http://127.0.0.1:$FRONTEND_PORT"; }
be_url() { echo "http://127.0.0.1:$BACKEND_PORT"; }
chk_fe_health()  { curl -fsS --max-time 10 "$(fe_url)$FRONTEND_HEALTH_PATH"; }
chk_fe_spa()     { curl -fsS --max-time 10 "$(fe_url)/" | grep -q '<app-root>'; }
chk_fe_env()     { curl -fsS --max-time 10 "$(fe_url)/assets/env.js" | grep -qF "apiBaseUrl: \"${API_BASE_URL%/}\""; }
chk_be_openapi() { curl -fsS --max-time 10 "$(be_url)$BACKEND_HEALTH_PATH"; }
chk_be_db()      { curl -fsS --max-time 60 "$(be_url)$BACKEND_DB_CHECK_PATH"; }
chk_cors() {
    local origin="${CORS_ORIGINS%%,*}"
    curl -fsS -o /dev/null -D - --max-time 10 -X OPTIONS \
        -H "Origin: $origin" -H "Access-Control-Request-Method: GET" "$(be_url)$BACKEND_DB_CHECK_PATH" \
        | tr -d '\r' | grep -qiF "access-control-allow-origin: $origin"
}
chk_network() {
    local members c
    members=" $(network_members) "
    for c in "${CONTAINERS[@]}"; do [[ "$members" == *" $c "* ]] || return 1; done
}
chk_fe_to_be() { docker exec "$FRONTEND_CONTAINER" wget -q -O /dev/null "http://$BACKEND_ALIAS:8201$BACKEND_HEALTH_PATH"; }
chk_be_to_db() { docker exec "$BACKEND_CONTAINER" python -c "import socket; socket.create_connection(('$DATABASE_ALIAS', 5432), 5)"; }
chk_restart() {
    local c
    for c in "${CONTAINERS[@]}"; do
        [[ "$(docker container inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$c")" == "unless-stopped" ]] || return 1
    done
}
chk_db_private() { [[ -z "$(docker port "$DATABASE_CONTAINER" 2>/dev/null)" ]]; }

verify() {
    FAILURES=0
    check "Front-End health        $(fe_url)$FRONTEND_HEALTH_PATH" chk_fe_health
    check "Front-End SPA           $(fe_url)/" chk_fe_spa
    check "Front-End runtime API   apiBaseUrl=$API_BASE_URL" chk_fe_env
    check "Back-End OpenAPI        $(be_url)$BACKEND_HEALTH_PATH" chk_be_openapi
    check "Back-End + database     $(be_url)$BACKEND_DB_CHECK_PATH" chk_be_db
    check "Browser -> API (CORS)   origin ${CORS_ORIGINS%%,*}" chk_cors
    check "All containers on       $NETWORK_NAME" chk_network
    check "Front-End -> Back-End   http://$BACKEND_ALIAS:8201 (NetCogitia DNS)" chk_fe_to_be
    check "Back-End -> Database    $DATABASE_ALIAS:5432 (NetCogitia DNS)" chk_be_to_db
    check "Restart policy          unless-stopped" chk_restart
    check "Database not published  (internal only)" chk_db_private
    [[ $FAILURES -eq 0 ]] || die "$FAILURES verification check(s) failed"
}

status() {
    header "Terra-Cogitia status"
    local c
    for c in "${CONTAINERS[@]}"; do
        if container_exists "$c"; then
            log "$(docker container inspect -f '{{.Name}}  {{.State.Status}}  {{if .State.Health}}{{.State.Health.Status}}{{end}}  {{.Config.Image}}' "$c" | sed 's#^/##')"
        else
            log "$c  (absent)"
        fi
    done
    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        log "network $NETWORK_NAME: $(network_members)"
    else
        log "network $NETWORK_NAME: (absent)"
    fi
    log "images (label $IMAGE_LABEL):"
    docker images --filter "label=$IMAGE_LABEL" --format '    {{.Repository}}:{{.Tag}}  {{.ID}}  {{.Size}}'
    local v
    for v in "${VOLUMES[@]}"; do
        if docker volume inspect "$v" >/dev/null 2>&1; then log "volume $v: present"; else log "volume $v: (absent)"; fi
    done
}

# --- Commands ------------------------------------------------------------------

cmd_deploy() {
    local clean_tar=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --clean-tar) clean_tar=true; shift ;;
            *) echo "Unknown deploy option: $1" >&2; exit 2 ;;
        esac
    done

    header "Preflight"
    require_docker
    load_env
    [[ -f "$COMPOSE_FILE" ]] || die "Missing $COMPOSE_FILE"
    [[ -f "$DEPLOY_DIR/secrets/database.env" && -f "$DEPLOY_DIR/secrets/backend.env" ]] || die "Missing secrets in $DEPLOY_DIR/secrets"
    compose config --quiet || die "docker-compose.yml / cogitia.env are inconsistent"
    ok "docker $(docker version --format '{{.Server.Version}}'), compose $(docker compose version --short)"

    header "Database backup"
    backup_database predeploy

    header "Network"
    ensure_network

    header "Images"
    load_images

    header "Containers"
    remove_stray_containers
    compose up -d --remove-orphans

    header "Health"
    wait_healthy

    header "Verification"
    verify

    header "Cleanup (Terra-Cogitia dangling images only)"
    docker image prune -f --filter "label=$IMAGE_LABEL" | sed 's/^/    /'
    if $clean_tar; then
        rm -f "$IMAGES_DIR"/*.tar
        ok "Removed image archives from $IMAGES_DIR"
    fi

    status
    echo
    ok "Deployment complete"
}

cmd_clean() {
    local purge_data=false remove_nginx=false keep_images=false
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --purge-data)   purge_data=true; shift ;;
            --remove-nginx) remove_nginx=true; shift ;;
            --keep-images)  keep_images=true; shift ;;
            *) echo "Unknown clean option: $1" >&2; exit 2 ;;
        esac
    done
    require_docker
    load_env

    header "Cleaning Terra-Cogitia"
    if $purge_data; then backup_database prepurge; fi

    local c v members ids
    for c in "${CONTAINERS[@]}"; do
        if container_exists "$c"; then docker rm -f "$c" >/dev/null; ok "container $c removed"; else log "container $c -- not present"; fi
    done

    if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
        members="$(network_members)"
        if [[ -z "${members// /}" ]]; then
            docker network rm "$NETWORK_NAME" >/dev/null; ok "network $NETWORK_NAME removed"
        else
            warn "network $NETWORK_NAME kept: still used by $members"
        fi
    else
        log "network $NETWORK_NAME -- not present"
    fi

    if $purge_data; then
        for v in "${VOLUMES[@]}"; do
            if docker volume inspect "$v" >/dev/null 2>&1; then docker volume rm "$v" >/dev/null; ok "volume $v removed"; else log "volume $v -- not present"; fi
        done
    else
        log "volumes kept: ${VOLUMES[*]} (use --purge-data to delete)"
    fi

    if ! $keep_images; then
        ids="$( { docker images -q --filter "label=$IMAGE_LABEL"; for v in "${IMAGES[@]}"; do docker image inspect -f '{{.Id}}' "$v" 2>/dev/null || true; done; } | sort -u)"
        if [[ -n "$ids" ]]; then
            # shellcheck disable=SC2086
            docker rmi -f $ids >/dev/null
            ok "Terra-Cogitia images removed ($(echo "$ids" | wc -l))"
        else
            log "images -- none present"
        fi
    fi

    rm -f "$IMAGES_DIR"/*.tar
    rm -rf "$DEPLOY_DIR/secrets"
    ok "image archives and secrets removed from $DEPLOY_DIR (backups kept in $BACKUP_DIR)"

    if $remove_nginx; then remove_nginx_site; fi

    header "Verification"
    FAILURES=0
    for c in "${CONTAINERS[@]}"; do check "container $c absent" bash -c "! docker container inspect '$c'"; done
    if ! $keep_images; then
        check "Terra-Cogitia images absent" bash -c "[[ -z \"\$(docker images -q --filter 'label=$IMAGE_LABEL')\" ]]"
    fi
    if $purge_data; then
        for v in "${VOLUMES[@]}"; do check "volume $v absent" bash -c "! docker volume inspect '$v'"; done
    fi
    [[ $FAILURES -eq 0 ]] || die "$FAILURES cleanup check(s) failed"
    ok "Cleanup complete"
}

cmd_apply_secrets() {
    # Re-reads secrets/backend.env into Cogitia-BackEnd. Env files are only read when a
    # container is created, so the Back-End is recreated (not just restarted). Images,
    # database and Front-End are untouched.
    header "Apply secrets"
    require_docker
    load_env
    [[ -f "$DEPLOY_DIR/secrets/backend.env" ]] || die "Missing $DEPLOY_DIR/secrets/backend.env"
    container_exists "$BACKEND_CONTAINER" || die "$BACKEND_CONTAINER is not deployed -- run deploy-all.ps1 first"
    local before after
    before="$(docker container inspect -f '{{.Id}}' "$BACKEND_CONTAINER")"
    compose up -d --no-deps --force-recreate backend
    after="$(docker container inspect -f '{{.Id}}' "$BACKEND_CONTAINER")"
    [[ "$before" != "$after" ]] || die "$BACKEND_CONTAINER was not recreated"
    ok "$BACKEND_CONTAINER recreated with the new secrets"

    header "Health"
    wait_healthy

    header "Verification"
    verify
    ok "Secrets applied"
}

# --- Host nginx vhost (PlanningPowerTools pattern: host nginx + certbot) -------

nginx_paths() {
    # Sets NGINX_SITE (file nginx reads) and NGINX_LINK (sites-enabled symlink, Debian layout only).
    NGINX_LINK=""
    if [[ -d /etc/nginx/sites-available && -d /etc/nginx/sites-enabled ]]; then
        NGINX_SITE="/etc/nginx/sites-available/$NGINX_SITE_NAME"
        NGINX_LINK="/etc/nginx/sites-enabled/$NGINX_SITE_NAME"
    elif [[ -d /etc/nginx/http.d ]]; then
        NGINX_SITE="/etc/nginx/http.d/$NGINX_SITE_NAME"
    else
        NGINX_SITE="/etc/nginx/conf.d/$NGINX_SITE_NAME"
    fi
}

reload_nginx() {
    nginx -s reload 2>/dev/null || systemctl reload nginx 2>/dev/null || rc-service nginx reload 2>/dev/null \
        || die "nginx reload failed"
    sleep 2   # reload is asynchronous: let new workers take over before anything verifies
}

cmd_nginx() {
    load_env
    [[ -n "${APP_DOMAIN:-}" && -n "${API_DOMAIN:-}" && -n "${CERT_NAME:-}" ]] || die "APP_DOMAIN / API_DOMAIN / CERT_NAME missing in $ENV_FILE"
    if ! command -v nginx >/dev/null; then
        warn "nginx is not installed on this host -- public vhost for $APP_DOMAIN / $API_DOMAIN skipped"
        exit 3
    fi
    nginx_paths

    local tpl mode
    if [[ -f "/etc/letsencrypt/live/$CERT_NAME/fullchain.pem" ]]; then
        tpl="$NGINX_TPL_DIR/terra-cogitia-https.conf.template"; mode="HTTPS"
    else
        tpl="$NGINX_TPL_DIR/terra-cogitia-http.conf.template"; mode="HTTP only (no certificate yet -- run renew-certificates.ps1 -Issue)"
    fi
    [[ -f "$tpl" ]] || die "Missing template $tpl"

    local rendered previous="$NGINX_TPL_DIR/$NGINX_SITE_NAME.previous"
    rendered="$(mktemp)"
    sed -e "s|{{APP_DOMAIN}}|$APP_DOMAIN|g" -e "s|{{API_DOMAIN}}|$API_DOMAIN|g" \
        -e "s|{{FRONTEND_PORT}}|$FRONTEND_PORT|g" -e "s|{{BACKEND_PORT}}|$BACKEND_PORT|g" \
        -e "s|{{CERT_NAME}}|$CERT_NAME|g" "$tpl" > "$rendered"

    local conflicts
    conflicts="$(grep -rlsE "server_name[^;]*[[:space:]](${APP_DOMAIN//./\\.}|${API_DOMAIN//./\\.})[[:space:];]" /etc/nginx 2>/dev/null \
        | grep -vF "$NGINX_SITE_NAME" || true)"
    [[ -z "$conflicts" ]] || warn "Other nginx files also declare $APP_DOMAIN/$API_DOMAIN: $conflicts"

    if [[ -f "$NGINX_SITE" ]] && cmp -s "$rendered" "$NGINX_SITE"; then
        rm -f "$rendered"
        [[ -z "$NGINX_LINK" || -L "$NGINX_LINK" ]] || ln -s "$NGINX_SITE" "$NGINX_LINK"
        ok "nginx vhost unchanged ($mode): $NGINX_SITE"
        return 0
    fi

    rm -f "$previous"
    [[ -f "$NGINX_SITE" ]] && cp -p "$NGINX_SITE" "$previous"
    install -m 644 "$rendered" "$NGINX_SITE"
    rm -f "$rendered"
    [[ -z "$NGINX_LINK" || -L "$NGINX_LINK" ]] || ln -s "$NGINX_SITE" "$NGINX_LINK"

    local test_output
    if ! test_output="$(nginx -t 2>&1)"; then
        echo "$test_output" | sed 's/^/    /'
        if [[ -f "$previous" ]]; then cp -p "$previous" "$NGINX_SITE"; else rm -f "$NGINX_SITE" ${NGINX_LINK:+"$NGINX_LINK"}; fi
        die "nginx -t failed with the new Terra-Cogitia vhost -- previous configuration restored"
    fi
    reload_nginx
    ok "nginx vhost installed ($mode): $NGINX_SITE"
}

remove_nginx_site() {
    command -v nginx >/dev/null || { log "nginx not installed -- nothing to remove"; return 0; }
    nginx_paths
    if [[ -f "$NGINX_SITE" || -L "${NGINX_LINK:-/nonexistent}" ]]; then
        rm -f "$NGINX_SITE" ${NGINX_LINK:+"$NGINX_LINK"}
        nginx -t >/dev/null 2>&1 || die "nginx -t failed after removing the Terra-Cogitia vhost"
        reload_nginx
        ok "nginx vhost removed ($NGINX_SITE); certificates kept in /etc/letsencrypt"
    else
        log "nginx vhost -- not present"
    fi
}

# --- Certificates (certbot, nginx authenticator -- same as PlanningPowerTools) --

require_certbot() { command -v certbot >/dev/null || die "certbot is not installed on this server"; }

cmd_cert_status() {
    load_env; require_certbot
    certbot certificates --cert-name "$CERT_NAME" 2>/dev/null || true
}

cmd_cert_issue() {
    load_env; require_certbot
    local email="${1:-}"; shift || true
    [[ "$email" =~ ^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$ ]] || { echo "cert-issue: a valid email is required" >&2; exit 2; }
    local -a flags=(certonly --nginx --cert-name "$CERT_NAME" -d "$APP_DOMAIN" -d "$API_DOMAIN"
                    --non-interactive --agree-tos -m "$email" --keep-until-expiring --no-random-sleep-on-renew)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) flags+=(--dry-run); shift ;;
            *) echo "Unknown cert-issue option: $1" >&2; exit 2 ;;
        esac
    done
    timeout 300 certbot "${flags[@]}"
}

cmd_cert_renew() {
    load_env; require_certbot
    local -a flags=(renew --cert-name "$CERT_NAME" --non-interactive --no-random-sleep-on-renew)
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --dry-run) flags+=(--dry-run); shift ;;
            --force)   flags+=(--force-renewal); shift ;;
            *) echo "Unknown cert-renew option: $1" >&2; exit 2 ;;
        esac
    done
    timeout 180 certbot "${flags[@]}"
}

# --- Dispatch --------------------------------------------------------------------

command="${1:-}"
[[ $# -gt 0 ]] && shift
case "$command" in
    deploy)      cmd_deploy "$@" ;;
    clean)       cmd_clean "$@" ;;
    apply-secrets) cmd_apply_secrets ;;
    status)      require_docker; load_env; status ;;
    backup)      require_docker; load_env; backup_database manual ;;
    nginx)       cmd_nginx ;;
    cert-status) cmd_cert_status ;;
    cert-issue)  cmd_cert_issue "$@" ;;
    cert-renew)  cmd_cert_renew "$@" ;;
    *)
        sed -n '2,23p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
        exit 2
        ;;
esac
