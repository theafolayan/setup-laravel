#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="setup_staging.sh"
WWW_ROOT="/var/www"

PROJECT=""
DOMAIN=""
SUFFIX="-staging"
BRANCH=""
METHOD="auto"
DNS_CONFIRM=""
CERTBOT_EMAIL=""
FPM_SOCKET_OVERRIDE=""
WITH_WWW=0
WITH_STORAGE=0
KEEP_DB_CONFIG=0
KEEP_MAIL=0
INSTALL_SCHEDULER=0
INSTALL_QUEUE=0
COMPOSER_DEV=0
SKIP_SSL=0
FORCE=0
NON_INTERACTIVE=0
DRY_RUN=0

usage() {
    cat <<'USAGE'
Usage: setup_staging.sh [options]

Clones an existing app in /var/www into a sibling staging copy, reuses the same
Nginx and PHP-FPM configuration, and issues an SSL certificate for the staging
domain. The staging .env is copied from the source so you only have to tweak
credentials afterwards.

  -p, --project NAME        Existing folder name in /var/www (prompted if omitted)
  -d, --domain DOMAIN       Staging domain, e.g. staging.example.com (prompted if omitted)
      --suffix SUFFIX       Suffix for the staging folder (default -staging)
      --method auto|git|copy  How to duplicate the code (default auto:
                              git clone when the source is a repo, else file copy)
      --branch BRANCH       Branch to clone (default: branch checked out in the source)
      --dns-confirm yes|no  Confirm the staging DNS A record already points here
      --email ADDRESS       Email for Let's Encrypt (default admin@<domain>)
      --fpm-socket PATH     Override the detected PHP-FPM socket
      --with-www            Also request a certificate for www.<domain>
      --with-storage        Copy storage/app from the source (prod uploads)
      --keep-db-config      Keep DB_DATABASE as-is instead of appending _staging
      --keep-mail           Keep MAIL_MAILER as-is instead of forcing "log"
      --scheduler           Install the schedule:run cron for the staging app
      --queue               Install a Supervisor queue worker for the staging app
      --dev                 composer install with dev dependencies
      --skip-ssl            Do not run Certbot
      --force               Move an existing staging folder aside and rebuild
  -n, --non-interactive     Do not prompt for input
      --dry-run             Show actions without executing
  -h, --help                Show this message

Examples:
  sudo ./setup_staging.sh -p mytherapistng -d staging.mytherapist.ng
  sudo ./setup_staging.sh -p mytherapistng -d staging.mytherapist.ng --branch develop
  sudo ./setup_staging.sh -n -p mytherapistng -d staging.mytherapist.ng --dns-confirm yes
USAGE
}

log() {
    echo "[$(date +'%F %T')] $*"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_cmd() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        printf 'DRY-RUN:'
        printf ' %q' "$@"
        printf '\n'
    else
        "$@"
    fi
}

prompt_if_unset() {
    local var="$1" prompt="$2" default="$3"
    declare -n ref="$var"
    if [[ -z "${ref:-}" && "$NON_INTERACTIVE" -eq 0 ]]; then
        read -rp "$prompt [$default]: " ref
    fi
    ref="${ref:-$default}"
}

require_root() {
    if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
        echo "This script must be run as root."
        exit 1
    fi
}

backup_file() {
    local file="$1"
    [[ -f "$file" ]] || return 0
    local ts
    ts="$(date +%Y%m%d_%H%M%S)"
    run_cmd cp -a "$file" "${file}.bak.${ts}"
    log "Backup created: ${file}.bak.${ts}"
}

# Source-controlled git calls run as root against www-data owned trees, so pin
# safe.directory per call rather than mutating the global git config.
git_src() {
    git -c safe.directory="$SRC_PATH" -C "$SRC_PATH" "$@"
}

set_env_value() {
    local file="$1" key="$2" value="$3"
    if [[ ! -f "$file" ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "DRY-RUN: would set ${key}=${value} in ${file}"
            return 0
        fi
        log "Env file not found: $file"
        return 1
    fi
    if grep -Eq "^[[:space:]]*#?[[:space:]]*${key}[[:space:]]*=" "$file"; then
        run_cmd perl -i -pe "s~^[\\t ]*#?[\\t ]*${key}[\\t ]*=.*~${key}=${value}~" "$file"
    else
        run_cmd bash -c "printf '\n%s=%s\n' '$key' '$value' >> '$file'"
    fi
}

get_env_value() {
    local file="$1" key="$2"
    [[ -f "$file" ]] || return 0
    grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" \
        | head -n1 \
        | cut -d= -f2- \
        | tr -d '"' \
        | tr -d "'" \
        | xargs 2>/dev/null || true
}

detect_source_vhost() {
    local match=""
    if [[ -d /etc/nginx/sites-available ]]; then
        match="$(grep -Rls "root ${SRC_PATH}/public;" /etc/nginx/sites-available 2>/dev/null | head -n1 || true)"
    fi
    echo "$match"
}

detect_fpm_socket() {
    local socket=""
    if [[ -n "$SOURCE_VHOST" && -f "$SOURCE_VHOST" ]]; then
        socket="$(grep -Eo 'fastcgi_pass[[:space:]]+unix:[^;]+' "$SOURCE_VHOST" \
            | head -n1 \
            | sed -E 's/.*unix:[[:space:]]*//' || true)"
    fi
    if [[ -z "$socket" ]]; then
        local candidate
        for candidate in /run/php/php*-fpm.sock /var/run/php/php*-fpm.sock; do
            if [[ -S "$candidate" ]]; then socket="$candidate"; fi
        done
    fi
    echo "$socket"
}

detect_php_binary() {
    local version=""
    version="$(basename "$FPM_SOCKET" 2>/dev/null | sed -nE 's/^php([0-9]+\.[0-9]+)-fpm\.sock$/\1/p' || true)"
    if [[ -n "$version" && -x "/usr/bin/php${version}" ]]; then
        echo "/usr/bin/php${version}"
        return
    fi
    command -v php || true
}

validate_inputs() {
    if [[ "$PROJECT" == */* || "$PROJECT" == *".."* || -z "$PROJECT" ]]; then
        log "Invalid project name: '$PROJECT'. Pass the folder name only, e.g. -p myapp"
        exit 1
    fi
    if [[ -z "$DOMAIN" || "$DOMAIN" != *.* || "$DOMAIN" == *"/"* ]]; then
        log "Invalid domain: '$DOMAIN'. Pass a hostname, e.g. -d staging.example.com"
        exit 1
    fi
    case "$METHOD" in
        auto|git|copy) ;;
        *) log "Invalid --method: $METHOD. Use auto, git, or copy."; exit 1;;
    esac
}

list_projects() {
    find "$WWW_ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort || true
}

resolve_paths() {
    SRC_PATH="${WWW_ROOT}/${PROJECT}"
    STAGING_NAME="${PROJECT}${SUFFIX}"
    DEST_PATH="${WWW_ROOT}/${STAGING_NAME}"

    if [[ ! -d "$SRC_PATH" ]]; then
        log "Source project not found: $SRC_PATH"
        log "Available projects in ${WWW_ROOT}:"
        list_projects | sed 's/^/  - /'
        exit 1
    fi
    if [[ "$STAGING_NAME" == "$PROJECT" ]]; then
        log "Suffix must not be empty; staging folder would overwrite the source."
        exit 1
    fi
}

prepare_destination() {
    if [[ ! -e "$DEST_PATH" ]]; then
        return
    fi

    log "Staging path already exists: $DEST_PATH"
    if [[ "$FORCE" -ne 1 ]]; then
        log "Re-run with --force to move it aside and rebuild, or pick another --suffix."
        exit 1
    fi

    local archived
    archived="${DEST_PATH}.old.$(date +%Y%m%d_%H%M%S)"
    log "Moving existing staging folder to ${archived} (nothing is deleted)."
    run_cmd mv "$DEST_PATH" "$archived"
}

confirm_dns() {
    local server_ip
    server_ip="$(curl -4 -s --max-time 10 ifconfig.co 2>/dev/null || hostname -I | awk '{print $1}')"
    log "Point an A record for ${DOMAIN} to ${server_ip} before SSL is requested."
    prompt_if_unset DNS_CONFIRM "Is the DNS record for ${DOMAIN} in place? (yes/no)" "yes"
    if [[ "$DNS_CONFIRM" != "yes" ]]; then
        log "DNS not confirmed. Aborting before any changes are made."
        exit 1
    fi
}

copy_source_tree() {
    log "Copying ${SRC_PATH} to ${DEST_PATH}..."
    if command_exists rsync; then
        run_cmd rsync -a --exclude '.git' "${SRC_PATH}/" "${DEST_PATH}/"
    else
        run_cmd cp -a "$SRC_PATH" "$DEST_PATH"
        run_cmd rm -rf "${DEST_PATH}/.git"
    fi
}

clone_source() {
    local repo_url="" source_branch=""

    if [[ "$METHOD" != "copy" && -d "${SRC_PATH}/.git" ]]; then
        repo_url="$(git_src remote get-url origin 2>/dev/null || true)"
        source_branch="$(git_src rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
    fi

    if [[ "$METHOD" == "git" && -z "$repo_url" ]]; then
        log "--method git was requested but no 'origin' remote was found in ${SRC_PATH}."
        exit 1
    fi

    if [[ -z "$repo_url" ]]; then
        log "No git remote detected; duplicating files instead."
        copy_source_tree
        CLONE_METHOD="copy"
        return
    fi

    # In non-interactive mode a private HTTPS remote would otherwise hang on a
    # credential prompt nobody is around to answer; fail fast with git's own error.
    local git_prompt="1"
    if [[ "$NON_INTERACTIVE" -eq 1 ]]; then
        git_prompt="0"
    fi

    local target_branch="${BRANCH:-$source_branch}"
    if [[ -z "$target_branch" || "$target_branch" == "HEAD" ]]; then
        log "Cloning ${repo_url} into ${DEST_PATH} (default branch)..."
        run_cmd env "GIT_TERMINAL_PROMPT=${git_prompt}" git clone "$repo_url" "$DEST_PATH"
    else
        log "Cloning ${repo_url} (branch ${target_branch}) into ${DEST_PATH}..."
        run_cmd env "GIT_TERMINAL_PROMPT=${git_prompt}" git clone --branch "$target_branch" "$repo_url" "$DEST_PATH"
    fi
    CLONE_METHOD="git"
    CLONE_BRANCH="${target_branch:-default}"
}

copy_storage() {
    [[ "$WITH_STORAGE" -eq 1 ]] || return 0
    local src="${SRC_PATH}/storage/app"
    if [[ ! -d "$src" ]]; then
        log "No storage/app in the source; skipping storage copy."
        return 0
    fi
    log "Copying storage/app from the source project..."
    run_cmd mkdir -p "${DEST_PATH}/storage/app"
    if command_exists rsync; then
        run_cmd rsync -a "${src}/" "${DEST_PATH}/storage/app/"
    else
        run_cmd cp -a "${src}/." "${DEST_PATH}/storage/app/"
    fi
}

install_dependencies() {
    if ! command_exists composer; then
        log "Composer not found; skipping dependency install."
        return 0
    fi
    log "Installing Composer dependencies..."
    if [[ "$COMPOSER_DEV" -eq 1 ]]; then
        run_cmd env COMPOSER_ALLOW_SUPERUSER=1 composer install -d "$DEST_PATH" --no-interaction --prefer-dist
    else
        run_cmd env COMPOSER_ALLOW_SUPERUSER=1 composer install -d "$DEST_PATH" --no-interaction --prefer-dist --no-dev --optimize-autoloader
    fi
}

seed_env() {
    local src_env="${SRC_PATH}/.env"
    local dest_env="${DEST_PATH}/.env"

    if [[ -f "$src_env" ]]; then
        log "Copying .env from the source project..."
        run_cmd cp -a "$src_env" "$dest_env"
    elif [[ -f "${DEST_PATH}/.env.example" ]]; then
        log "Source .env not found; falling back to .env.example."
        run_cmd cp "${DEST_PATH}/.env.example" "$dest_env"
    else
        log "No .env or .env.example available; you will have to create ${dest_env} yourself."
        return 0
    fi

    set_env_value "$dest_env" "APP_ENV" "staging"
    set_env_value "$dest_env" "APP_DEBUG" "true"
    set_env_value "$dest_env" "APP_URL" "https://${DOMAIN}"

    # A staging site that inherits the production database or mailer will happily
    # write to it before anyone edits .env, so both are pointed somewhere inert.
    if [[ "$KEEP_DB_CONFIG" -eq 1 ]]; then
        log "Keeping DB_DATABASE from the source .env as requested."
    else
        local src_db
        src_db="$(get_env_value "$src_env" "DB_DATABASE")"
        if [[ -n "$src_db" ]]; then
            STAGING_DB="${src_db}_staging"
            set_env_value "$dest_env" "DB_DATABASE" "$STAGING_DB"
            log "DB_DATABASE set to ${STAGING_DB} (not created; see the summary)."
        fi
    fi

    if [[ "$KEEP_MAIL" -eq 1 ]]; then
        log "Keeping MAIL_MAILER from the source .env as requested."
    else
        set_env_value "$dest_env" "MAIL_MAILER" "log"
        MAIL_NEUTRALISED=1
    fi
}

prepare_laravel() {
    if [[ -z "$PHP_BINARY" ]]; then
        log "No PHP binary found; skipping artisan steps."
        return 0
    fi
    if [[ ! -f "${DEST_PATH}/artisan" && "$DRY_RUN" -eq 0 ]]; then
        log "No artisan file in ${DEST_PATH}; skipping artisan steps."
        return 0
    fi

    # A fresh key keeps staging sessions, cookies and encrypted columns separate
    # from production even though the rest of the file was copied verbatim.
    if [[ -f "${DEST_PATH}/.env" || "$DRY_RUN" -eq 1 ]]; then
        log "Generating a fresh APP_KEY for staging..."
        run_cmd "$PHP_BINARY" "${DEST_PATH}/artisan" key:generate --force --no-interaction
    fi

    if [[ -d "${SRC_PATH}/public/storage" ]]; then
        log "Linking storage into public/..."
        run_cmd "$PHP_BINARY" "${DEST_PATH}/artisan" storage:link --no-interaction || true
    fi

    # Deliberately no config:cache — the whole point is that .env gets edited next.
    log "Clearing caches (config is intentionally left uncached for staging)..."
    run_cmd "$PHP_BINARY" "${DEST_PATH}/artisan" optimize:clear --no-interaction || true
}

fix_permissions() {
    log "Applying file permissions..."
    run_cmd find "$DEST_PATH" -type f -exec chmod 644 {} +
    run_cmd find "$DEST_PATH" -type d -exec chmod 755 {} +
    if [[ -d "${DEST_PATH}/storage" ]]; then
        run_cmd chmod -R ug+rwx "${DEST_PATH}/storage"
    fi
    if [[ -d "${DEST_PATH}/bootstrap/cache" ]]; then
        run_cmd chmod -R ug+rwx "${DEST_PATH}/bootstrap/cache"
    fi
    run_cmd chown -R www-data:www-data "$DEST_PATH"
}

write_nginx_vhost() {
    if ! command_exists nginx; then
        log "Nginx not installed; skipping vhost creation. The code is deployed but not served."
        return 0
    fi

    NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
    backup_file "$NGINX_CONF"

    local server_names="$DOMAIN"
    if [[ "$WITH_WWW" -eq 1 ]]; then server_names="${DOMAIN} www.${DOMAIN}"; fi

    log "Writing Nginx vhost: $NGINX_CONF"
    run_cmd tee "$NGINX_CONF" >/dev/null <<EOF
server {
    listen 80;
    server_name ${server_names};
    root ${DEST_PATH}/public;
    index index.php index.html;

    # Staging should never be indexed.
    add_header X-Robots-Tag "noindex, nofollow" always;

    gzip on;
    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;
    gzip_min_length 1024;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~* \.(?:css|js|jpg|jpeg|gif|png|svg|ico)\$ {
        expires 7d;
        add_header Cache-Control "public";
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:${FPM_SOCKET};
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;
}
EOF

    run_cmd ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/

    # This nginx also serves production. If the generated vhost does not validate,
    # unlink it immediately rather than leaving a broken config that would take
    # every other site down on the next reload.
    if run_cmd nginx -t; then
        run_cmd systemctl reload nginx
        log "Nginx reloaded with the staging vhost."
    else
        NGINX_ROLLED_BACK=1
        log "nginx -t failed. Disabling the staging vhost to protect the running config."
        run_cmd rm -f "/etc/nginx/sites-enabled/${DOMAIN}"
        if run_cmd nginx -t; then
            log "Existing nginx config is valid again; staging is deployed but not served."
        else
            log "nginx -t still fails - the config was already broken before this run. Fix it manually."
        fi
        log "The generated vhost is kept at ${NGINX_CONF} for inspection."
    fi
}

request_ssl() {
    if [[ "$SKIP_SSL" -eq 1 ]]; then
        log "Skipping SSL as requested (--skip-ssl)."
        return 0
    fi
    if [[ "$NGINX_ROLLED_BACK" -eq 1 ]]; then
        log "Staging vhost is not enabled; skipping SSL."
        return 0
    fi
    if [[ -z "$NGINX_CONF" ]]; then
        log "No staging vhost was written; skipping SSL."
        return 0
    fi

    if ! command_exists certbot; then
        log "Installing Certbot..."
        run_cmd apt-get update -y
        run_cmd apt-get install -y certbot python3-certbot-nginx
    fi

    local email="${CERTBOT_EMAIL:-admin@${DOMAIN}}"
    local certbot_args=(--nginx -d "$DOMAIN")
    if [[ "$WITH_WWW" -eq 1 ]]; then certbot_args+=(-d "www.${DOMAIN}"); fi
    certbot_args+=(--non-interactive --agree-tos --redirect -m "$email")

    log "Requesting a certificate for ${DOMAIN}..."
    # The app is already deployed and serving on HTTP by now, so a certbot failure
    # (usually DNS that has not propagated) must not tear the whole run down.
    if run_cmd certbot "${certbot_args[@]}"; then
        run_cmd systemctl enable --now certbot.timer
        SSL_READY=1
        log "SSL issued and HTTP redirected to HTTPS."
    else
        SSL_FAILED=1
        log "Certbot failed. The site is live over HTTP; retry once DNS resolves with:"
        log "  sudo certbot ${certbot_args[*]}"
    fi
}

install_scheduler() {
    [[ "$INSTALL_SCHEDULER" -eq 1 ]] || return 0
    [[ -n "$PHP_BINARY" ]] || { log "No PHP binary; skipping scheduler cron."; return 0; }

    # cron.d rejects filenames containing dots.
    local cron_name="${STAGING_NAME//./_}"
    local cron_file="/etc/cron.d/${cron_name}_schedule"
    log "Installing scheduler cron: $cron_file"
    run_cmd tee "$cron_file" >/dev/null <<EOF
SHELL=/bin/bash
PATH=/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin

* * * * * www-data cd ${DEST_PATH} && ${PHP_BINARY} artisan schedule:run >> ${DEST_PATH}/storage/logs/scheduler.log 2>&1
EOF
    run_cmd chmod 644 "$cron_file"
    run_cmd systemctl restart cron
}

install_queue_worker() {
    [[ "$INSTALL_QUEUE" -eq 1 ]] || return 0
    [[ -n "$PHP_BINARY" ]] || { log "No PHP binary; skipping queue worker."; return 0; }

    if ! command_exists supervisorctl; then
        log "Installing Supervisor..."
        run_cmd apt-get install -y supervisor
        run_cmd systemctl enable --now supervisor
    fi

    local conf="/etc/supervisor/conf.d/${STAGING_NAME}-queue.conf"
    log "Installing Supervisor queue worker: $conf"
    run_cmd tee "$conf" >/dev/null <<EOF
[program:${STAGING_NAME}-queue]
process_name=%(program_name)s_%(process_num)02d
command=${PHP_BINARY} ${DEST_PATH}/artisan queue:work --tries=3 --sleep=3
autostart=true
autorestart=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/supervisor/${STAGING_NAME}-queue.log
stopwaitsecs=3600
directory=${DEST_PATH}
EOF
    run_cmd supervisorctl reread
    run_cmd supervisorctl update
}

print_summary() {
    local scheme="http"
    if [[ "$SSL_READY" -eq 1 ]]; then scheme="https"; fi

    echo
    log "Staging environment ready."
    echo "  Source:      ${SRC_PATH}"
    echo "  Staging:     ${DEST_PATH}"
    echo "  Method:      ${CLONE_METHOD}${CLONE_BRANCH:+ (branch ${CLONE_BRANCH})}"
    echo "  URL:         ${scheme}://${DOMAIN}"
    echo "  Nginx vhost: ${NGINX_CONF:-not created}"
    echo "  PHP-FPM:     ${FPM_SOCKET:-not detected}"
    if [[ "$SSL_FAILED" -eq 1 ]]; then
        echo "  SSL:         FAILED - see the certbot command logged above"
    fi
    echo
    echo "Next steps:"
    echo "  1. Edit ${DEST_PATH}/.env and set the staging credentials."
    if [[ -n "$STAGING_DB" ]]; then
        echo "     DB_DATABASE is set to '${STAGING_DB}' and has NOT been created yet:"
        echo "       mysql -uroot -p -e \"CREATE DATABASE ${STAGING_DB};\""
    fi
    if [[ "$MAIL_NEUTRALISED" -eq 1 ]]; then
        echo "     MAIL_MAILER was forced to 'log' so staging cannot email real users."
    fi
    echo "  2. Run migrations: sudo -u www-data ${PHP_BINARY:-php} ${DEST_PATH}/artisan migrate"
    echo "  3. Config is intentionally left uncached so your .env edits take effect."
    if [[ "$INSTALL_SCHEDULER" -eq 0 ]]; then
        echo "  4. Scheduler and queue workers were not installed; add them with --scheduler / --queue."
    fi
    echo
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--project) PROJECT="${2:-}"; shift 2;;
        -d|--domain) DOMAIN="${2:-}"; shift 2;;
        --suffix) SUFFIX="${2:-}"; shift 2;;
        --method) METHOD="${2:-}"; shift 2;;
        --branch) BRANCH="${2:-}"; shift 2;;
        --dns-confirm) DNS_CONFIRM="${2:-}"; shift 2;;
        --email) CERTBOT_EMAIL="${2:-}"; shift 2;;
        --fpm-socket) FPM_SOCKET_OVERRIDE="${2:-}"; shift 2;;
        --with-www) WITH_WWW=1; shift;;
        --with-storage) WITH_STORAGE=1; shift;;
        --keep-db-config) KEEP_DB_CONFIG=1; shift;;
        --keep-mail) KEEP_MAIL=1; shift;;
        --scheduler) INSTALL_SCHEDULER=1; shift;;
        --queue) INSTALL_QUEUE=1; shift;;
        --dev) COMPOSER_DEV=1; shift;;
        --skip-ssl) SKIP_SSL=1; shift;;
        --force) FORCE=1; shift;;
        -n|--non-interactive) NON_INTERACTIVE=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown option: $1"; usage; exit 1;;
    esac
done

require_root

if [[ ! -d "$WWW_ROOT" ]]; then
    log "${WWW_ROOT} does not exist; nothing to stage."
    exit 1
fi

if [[ -z "$PROJECT" && "$NON_INTERACTIVE" -eq 0 ]]; then
    mapfile -t AVAILABLE < <(list_projects)
    if [[ ${#AVAILABLE[@]} -eq 0 ]]; then
        log "No applications found in ${WWW_ROOT}."
        exit 1
    fi
    echo "Select the project to stage:"
    select PROJECT in "${AVAILABLE[@]}"; do
        if [[ -n "${PROJECT:-}" ]]; then break; fi
        echo "Invalid selection."
    done
fi

prompt_if_unset PROJECT "Project folder in ${WWW_ROOT}" ""
prompt_if_unset DOMAIN "Staging domain (e.g. staging.example.com)" ""

validate_inputs
resolve_paths

SOURCE_VHOST="$(detect_source_vhost)"
FPM_SOCKET="${FPM_SOCKET_OVERRIDE:-$(detect_fpm_socket)}"
PHP_BINARY="$(detect_php_binary)"
CLONE_METHOD=""
CLONE_BRANCH=""
STAGING_DB=""
MAIL_NEUTRALISED=0
SSL_READY=0
SSL_FAILED=0
NGINX_CONF=""
NGINX_ROLLED_BACK=0

if [[ -z "$SOURCE_VHOST" ]]; then
    log "No existing vhost found for ${SRC_PATH}; a fresh staging vhost will still be written."
else
    log "Source vhost detected: $SOURCE_VHOST"
fi
if [[ -z "$FPM_SOCKET" ]]; then
    log "Could not detect a PHP-FPM socket. Pass --fpm-socket /run/php/phpX.Y-fpm.sock."
    exit 1
fi

log "Staging '${PROJECT}' as '${STAGING_NAME}' on ${DOMAIN}"
log "  Source path:  ${SRC_PATH}"
log "  Staging path: ${DEST_PATH}"
log "  PHP-FPM:      ${FPM_SOCKET}"
log "  PHP binary:   ${PHP_BINARY:-not found}"

# Confirm DNS before anything on disk is touched, so aborting here is a no-op.
confirm_dns
prepare_destination

clone_source
copy_storage
# .env is seeded before composer install so Laravel's post-install scripts
# (package:discover et al) boot against real config.
seed_env
install_dependencies
prepare_laravel
fix_permissions
write_nginx_vhost
request_ssl
install_scheduler
install_queue_worker

print_summary
log "${SCRIPT_NAME} complete."
