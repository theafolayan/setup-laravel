#!/usr/bin/env bash
set -euo pipefail

SCRIPT_NAME="boost_performance.sh"
NON_INTERACTIVE=0
DRY_RUN=0
RAM_GB=""
PHP_MAX_CHILDREN_OVERRIDE=""
PHP_MEMORY_PER_CHILD_MB="110" # Laravel apps tend to be memory-heavier per worker
NGINX_WORKER_CONNECTIONS_OVERRIDE=""
SKIP_ULIMITS=0

usage() {
    cat <<'USAGE'
Usage: boost_performance.sh [options]
  --ram-gb 2|8|16|32              Server RAM in GB (prompted if omitted)
  --php-max-children N            Override pm.max_children
  --php-mem-per-child-mb N        Estimated MB per php-fpm child (default 110)
  --nginx-worker-connections N    Override nginx worker_connections
  --skip-ulimits                  Skip raising systemd NOFILE limits
  -n, --non-interactive           Do not prompt for input
  --dry-run                       Show actions without executing
  -h, --help                      Show this message

Examples:
  sudo ./boost_performance.sh
  sudo ./boost_performance.sh --ram-gb 8
  sudo ./boost_performance.sh --ram-gb 16 --php-mem-per-child-mb 140
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

detect_php_version() {
    local detected=""
    if [[ -d /etc/php ]]; then
        detected="$(find /etc/php -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -V | tail -n1 || true)"
    fi
    if [[ -z "$detected" ]]; then
        detected="$(php -r 'echo PHP_MAJOR_VERSION . "." . PHP_MINOR_VERSION;' 2>/dev/null || true)"
    fi
    echo "$detected"
}

detect_php_fpm_service() {
    local svc=""
    if command_exists systemctl; then
        svc="$(systemctl list-units --type=service --state=running 2>/dev/null \
            | awk '{print $1}' \
            | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' \
            | head -n1 || true)"
        if [[ -z "$svc" ]]; then
            svc="$(systemctl list-unit-files 2>/dev/null \
                | awk '{print $1}' \
                | grep -E '^php[0-9]+\.[0-9]+-fpm\.service$' \
                | sort -V \
                | tail -n1 || true)"
        fi
    fi
    echo "${svc:-php-fpm.service}"
}

set_php_ini_value() {
    local ini="$1" key="$2" value="$3"
    if grep -Eq "^[[:space:]]*;?[[:space:]]*${key}[[:space:]]*=" "$ini"; then
        run_cmd perl -i -pe "s~^[\\t ]*;?[\\t ]*${key}[\\t ]*=.*~${key}=${value}~" "$ini"
    else
        run_cmd bash -c "printf '\n%s=%s\n' '$key' '$value' >> '$ini'"
    fi
}

set_pool_value() {
    local file="$1" key="$2" value="$3"
    if grep -Eq "^[[:space:]]*;?[[:space:]]*${key}[[:space:]]*=" "$file"; then
        run_cmd perl -i -pe "s~^[\\t ]*;?[\\t ]*${key}[\\t ]*=.*~${key} = ${value}~" "$file"
    else
        run_cmd bash -c "printf '\n%s = %s\n' '$key' '$value' >> '$file'"
    fi
}

ensure_http_directive() {
    local key="$1" value="$2" file="$3"
    if grep -Eq "^[[:space:]]*${key}[[:space:]]+" "$file"; then
        run_cmd perl -i -pe "s/^[\\t ]*${key}\\s+.*?;/    ${key} ${value};/mg" "$file"
    else
        run_cmd perl -0777 -i -pe "s~http\\s*\\{~http {\\n    ${key} ${value};~s" "$file"
    fi
}

calculate_profiles() {
    case "$RAM_GB" in
        2)
            NGINX_WORKER_CONNECTIONS_DEFAULT="2048"
            NGINX_KEEPALIVE_DEFAULT="15"
            PHP_MEMORY_LIMIT="256M"
            PHP_OPCACHE_MEM="128"
            PHP_PM_MAX_CHILDREN_DEFAULT="10"
            PHP_PM_START_SERVERS="3"
            PHP_PM_MIN_SPARE="2"
            PHP_PM_MAX_SPARE="5"
            ;;
        8)
            NGINX_WORKER_CONNECTIONS_DEFAULT="8192"
            NGINX_KEEPALIVE_DEFAULT="30"
            PHP_MEMORY_LIMIT="512M"
            PHP_OPCACHE_MEM="256"
            PHP_PM_MAX_CHILDREN_DEFAULT="40"
            PHP_PM_START_SERVERS="6"
            PHP_PM_MIN_SPARE="4"
            PHP_PM_MAX_SPARE="14"
            ;;
        16)
            NGINX_WORKER_CONNECTIONS_DEFAULT="16384"
            NGINX_KEEPALIVE_DEFAULT="45"
            PHP_MEMORY_LIMIT="512M"
            PHP_OPCACHE_MEM="384"
            PHP_PM_MAX_CHILDREN_DEFAULT="80"
            PHP_PM_START_SERVERS="10"
            PHP_PM_MIN_SPARE="8"
            PHP_PM_MAX_SPARE="24"
            ;;
        32)
            NGINX_WORKER_CONNECTIONS_DEFAULT="32768"
            NGINX_KEEPALIVE_DEFAULT="60"
            PHP_MEMORY_LIMIT="512M"
            PHP_OPCACHE_MEM="512"
            PHP_PM_MAX_CHILDREN_DEFAULT="160"
            PHP_PM_START_SERVERS="18"
            PHP_PM_MIN_SPARE="14"
            PHP_PM_MAX_SPARE="48"
            ;;
        *)
            log "Unsupported RAM size: $RAM_GB. Use 2, 8, 16, or 32."
            exit 1
            ;;
    esac
}

restart_service() {
    local svc="$1"
    if command_exists systemctl; then
        run_cmd systemctl restart "$svc"
    elif command_exists service; then
        run_cmd service "$svc" restart
    else
        log "Unable to restart $svc (no init system found)."
    fi
}

apply_nginx_tuning() {
    if ! command_exists nginx; then
        log "Nginx not detected; skipping web server tuning."
        return
    fi

    local nginx_conf="/etc/nginx/nginx.conf"
    if [[ ! -f "$nginx_conf" ]]; then
        log "Nginx config not found at $nginx_conf"
        return
    fi

    backup_file "$nginx_conf"

    local worker_connections="${NGINX_WORKER_CONNECTIONS_OVERRIDE:-$NGINX_WORKER_CONNECTIONS_DEFAULT}"
    local keepalive="$NGINX_KEEPALIVE_DEFAULT"

    if grep -Eq "^[[:space:]]*worker_processes" "$nginx_conf"; then
        run_cmd perl -i -pe 's/^[\t ]*worker_processes\s+.*;/worker_processes auto;/g' "$nginx_conf"
    else
        run_cmd perl -0777 -i -pe 's~(user\s+[^;]+;\s*)~\1\nworker_processes auto;\n~s' "$nginx_conf"
    fi

    if ! grep -Eq "^[[:space:]]*events[[:space:]]*\\{" "$nginx_conf"; then
        run_cmd bash -c "printf '\nevents {\n    worker_connections %s;\n    multi_accept on;\n}\n' '$worker_connections' >> '$nginx_conf'"
    else
        if ! command_exists python3; then
            if command_exists apt-get; then
                log "python3 not found; installing with apt-get."
                run_cmd apt-get update -y
                run_cmd apt-get install -y python3
            else
                log "python3 not found and apt-get unavailable; skipping events block update."
            fi
        fi

        if command_exists python3; then
            WORKER_CONNECTIONS="$worker_connections" NGINX_CONF="$nginx_conf" run_cmd bash -c "python3 - <<'PY'
import os
import re

path = os.environ['NGINX_CONF']
worker_connections = os.environ['WORKER_CONNECTIONS']

with open(path, 'r', encoding='utf-8') as handle:
    data = handle.read()

def rewrite_events(match):
    body = match.group(1)
    lines = []
    for line in body.splitlines():
        if re.match(r'\\s*worker_connections\\b', line):
            continue
        if re.match(r'\\s*multi_accept\\b', line):
            continue
        lines.append(line)

    while lines and not lines[0].strip():
        lines.pop(0)

    body_text = '\\n'.join(lines)
    if body_text and not body_text.endswith('\\n'):
        body_text += '\\n'

    return (
        'events {\\n'
        f'    worker_connections {worker_connections};\\n'
        '    multi_accept on;\\n'
        f'{body_text}'
        '}'
    )

updated, count = re.subn(r'events\\s*\\{(.*?)\\}', rewrite_events, data, flags=re.S)
if count == 0:
    updated = data

with open(path, 'w', encoding='utf-8') as handle:
    handle.write(updated)
PY"
        fi
    fi

    ensure_http_directive "keepalive_timeout" "$keepalive" "$nginx_conf"
    ensure_http_directive "sendfile" "on" "$nginx_conf"
    ensure_http_directive "tcp_nopush" "on" "$nginx_conf"
    ensure_http_directive "tcp_nodelay" "on" "$nginx_conf"
    ensure_http_directive "server_tokens" "off" "$nginx_conf"

    if ! grep -Eq "^[[:space:]]*open_file_cache" "$nginx_conf"; then
        run_cmd perl -0777 -i -pe 's~http\s*\{~http {\n    open_file_cache max=200000 inactive=20s;\n    open_file_cache_valid 30s;\n    open_file_cache_min_uses 2;\n    open_file_cache_errors on;~s' "$nginx_conf"
    fi

    if ! grep -Eq "^[[:space:]]*gzip[[:space:]]+on;" "$nginx_conf"; then
        run_cmd perl -0777 -i -pe 's~http\s*\{~http {\n    gzip on;\n    gzip_vary on;\n    gzip_proxied any;\n    gzip_comp_level 5;\n    gzip_min_length 1024;\n    gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript;~s' "$nginx_conf"
    fi

    if ! grep -Eq "^[[:space:]]*client_body_buffer_size" "$nginx_conf"; then
        run_cmd perl -0777 -i -pe 's~http\s*\{~http {\n    client_body_buffer_size 128k;\n    client_header_buffer_size 4k;\n    large_client_header_buffers 4 16k;~s' "$nginx_conf"
    fi

    run_cmd nginx -t
    restart_service nginx
    log "Nginx tuned and reloaded."
}

apply_php_fpm_tuning() {
    if ! command_exists php-fpm && ! command_exists php; then
        log "PHP is not installed; skipping PHP-FPM tuning."
        return
    fi

    local php_version
    php_version="$(detect_php_version)"
    if [[ -z "$php_version" ]]; then
        log "Could not detect PHP version under /etc/php."
        return
    fi

    local fpm_service
    fpm_service="$(detect_php_fpm_service)"

    local pool="/etc/php/${php_version}/fpm/pool.d/www.conf"
    local php_ini="/etc/php/${php_version}/fpm/php.ini"
    local opcache_ini="/etc/php/${php_version}/fpm/conf.d/10-opcache.ini"

    if [[ ! -f "$pool" ]]; then
        log "PHP-FPM pool not found at $pool"
        return
    fi
    if [[ ! -f "$php_ini" ]]; then
        log "php.ini not found at $php_ini"
        return
    fi
    if [[ ! -f "$opcache_ini" ]]; then
        log "Opcache ini not found at $opcache_ini"
        return
    fi

    backup_file "$pool"
    backup_file "$php_ini"
    backup_file "$opcache_ini"

    local max_children="${PHP_MAX_CHILDREN_OVERRIDE:-$PHP_PM_MAX_CHILDREN_DEFAULT}"

    local reserve_mb
    case "$RAM_GB" in
        2) reserve_mb="700" ;;
        8) reserve_mb="2000" ;;
        16) reserve_mb="3500" ;;
        32) reserve_mb="6000" ;;
        *) reserve_mb="2000" ;;
    esac

    local total_mb usable_mb calc_children
    total_mb=$(( RAM_GB * 1024 ))
    usable_mb=$(( total_mb - reserve_mb ))
    calc_children=$(( usable_mb / PHP_MEMORY_PER_CHILD_MB ))
    if [[ -z "${PHP_MAX_CHILDREN_OVERRIDE:-}" ]]; then
        (( calc_children < 8 )) && calc_children=8
        if (( calc_children < max_children )); then
            max_children="$calc_children"
        fi
    fi

    set_pool_value "$pool" "pm" "dynamic"
    set_pool_value "$pool" "pm.max_children" "$max_children"
    set_pool_value "$pool" "pm.start_servers" "$PHP_PM_START_SERVERS"
    set_pool_value "$pool" "pm.min_spare_servers" "$PHP_PM_MIN_SPARE"
    set_pool_value "$pool" "pm.max_spare_servers" "$PHP_PM_MAX_SPARE"
    set_pool_value "$pool" "pm.max_requests" "500"
    set_pool_value "$pool" "request_terminate_timeout" "60s"

    set_php_ini_value "$php_ini" "memory_limit" "$PHP_MEMORY_LIMIT"
    set_php_ini_value "$php_ini" "max_execution_time" "60"
    set_php_ini_value "$php_ini" "realpath_cache_size" "4096K"
    set_php_ini_value "$php_ini" "realpath_cache_ttl" "600"
    set_php_ini_value "$php_ini" "expose_php" "0"

    set_php_ini_value "$opcache_ini" "opcache.enable" "1"
    set_php_ini_value "$opcache_ini" "opcache.enable_cli" "1"
    set_php_ini_value "$opcache_ini" "opcache.memory_consumption" "$PHP_OPCACHE_MEM"
    set_php_ini_value "$opcache_ini" "opcache.interned_strings_buffer" "16"
    set_php_ini_value "$opcache_ini" "opcache.max_accelerated_files" "60000"
    set_php_ini_value "$opcache_ini" "opcache.validate_timestamps" "1"
    set_php_ini_value "$opcache_ini" "opcache.revalidate_freq" "2"
    set_php_ini_value "$opcache_ini" "opcache.save_comments" "1"

    restart_service "$fpm_service"
    log "PHP-FPM restarted: $fpm_service"
    log "PHP-FPM summary: pm.max_children=${max_children}, memory_limit=${PHP_MEMORY_LIMIT}, opcache.memory_consumption=${PHP_OPCACHE_MEM}"
}

apply_ulimits() {
    if [[ "$SKIP_ULIMITS" -eq 1 ]]; then
        log "Skipping ulimit changes per request."
        return
    fi

    if ! command_exists systemctl; then
        log "systemd not detected; skipping ulimit overrides."
        return
    fi

    log "Applying systemd file descriptor limits..."

    local nginx_dir="/etc/systemd/system/nginx.service.d"
    local nginx_override="${nginx_dir}/override.conf"
    run_cmd mkdir -p "$nginx_dir"
    backup_file "$nginx_override"
    run_cmd tee "$nginx_override" >/dev/null <<'EOF'
[Service]
LimitNOFILE=1048576
EOF

    local fpm_service fpm_name fpm_dir fpm_override
    fpm_service="$(detect_php_fpm_service)"
    fpm_name="${fpm_service%.service}"
    fpm_dir="/etc/systemd/system/${fpm_name}.service.d"
    fpm_override="${fpm_dir}/override.conf"
    run_cmd mkdir -p "$fpm_dir"
    backup_file "$fpm_override"
    run_cmd tee "$fpm_override" >/dev/null <<'EOF'
[Service]
LimitNOFILE=1048576
EOF

    run_cmd systemctl daemon-reload
    restart_service nginx
    restart_service "$fpm_service"
    log "systemd overrides applied and services restarted."
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ram-gb) RAM_GB="${2:-}"; shift 2;;
        --php-max-children) PHP_MAX_CHILDREN_OVERRIDE="${2:-}"; shift 2;;
        --php-mem-per-child-mb) PHP_MEMORY_PER_CHILD_MB="${2:-}"; shift 2;;
        --nginx-worker-connections) NGINX_WORKER_CONNECTIONS_OVERRIDE="${2:-}"; shift 2;;
        --skip-ulimits) SKIP_ULIMITS=1; shift;;
        -n|--non-interactive) NON_INTERACTIVE=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown option: $1"; usage; exit 1;;
    esac
done

require_root

prompt_if_unset RAM_GB "Server RAM size in GB (2, 8, 16, 32)" "8"

if [[ ! "$RAM_GB" =~ ^(2|8|16|32)$ ]]; then
    log "Invalid RAM_GB: $RAM_GB. Use 2, 8, 16, or 32."
    exit 1
fi

calculate_profiles

log "Selected profile: ${RAM_GB}GB"
log "Planned defaults:"
log "  Nginx worker_connections: ${NGINX_WORKER_CONNECTIONS_OVERRIDE:-$NGINX_WORKER_CONNECTIONS_DEFAULT}"
log "  Nginx keepalive_timeout:  ${NGINX_KEEPALIVE_DEFAULT}"
log "  PHP memory_limit:         ${PHP_MEMORY_LIMIT}"
log "  PHP opcache mem (MB):     ${PHP_OPCACHE_MEM}"
log "  PHP pm.max_children base: ${PHP_MAX_CHILDREN_OVERRIDE:-$PHP_PM_MAX_CHILDREN_DEFAULT}"
log "  PHP mem per child (MB):   ${PHP_MEMORY_PER_CHILD_MB}"

apply_nginx_tuning
apply_php_fpm_tuning
apply_ulimits

log "${SCRIPT_NAME} complete."
