#!/usr/bin/env bash
# Test suite for the helper scripts in this repository.
#
#   ./tests/run_tests.sh
#
# The scripts are sourced with SETUP_LARAVEL_LIB_ONLY=1, which stops them before
# their argument parsing, so the helpers can be exercised without root or a
# deployment. Tests that need the full flow run the script as a subprocess.
#
# Globals assigned in the test sections configure the sourced scripts, so the
# linter sees them as unused.
# shellcheck disable=SC2034
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKDIR=""

cleanup() {
    if [[ -n "$WORKDIR" && -d "$WORKDIR" ]]; then rm -rf "$WORKDIR"; fi
}
trap cleanup EXIT

WORKDIR="$(mktemp -d)"
# Sections run in subshells so each can source a script with its own globals.
# Results are appended here because a subshell cannot update the parent's counters.
TALLY="${WORKDIR}/tally"
: > "$TALLY"

ok() {
    echo P >> "$TALLY"
    printf '  \033[32mok\033[0m   %s\n' "$1"
}

not_ok() {
    echo F >> "$TALLY"
    printf '  \033[31mFAIL\033[0m %s\n' "$1"
    if [[ $# -gt 1 ]]; then
        printf '       expected: %s\n       actual:   %s\n' "$2" "${3:-}"
    fi
    return 0
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        ok "$label"
    else
        not_ok "$label" "$expected" "$actual"
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if [[ "$haystack" == *"$needle"* ]]; then
        ok "$label"
    else
        not_ok "$label" "output containing '$needle'" "$haystack"
    fi
}

section() {
    printf '\n\033[1m%s\033[0m\n' "$1"
}

# ---------------------------------------------------------------------------
section "boost_performance.sh: memory profiles"
# ---------------------------------------------------------------------------
(
    # shellcheck source=/dev/null
    SETUP_LARAVEL_LIB_ONLY=1 source "${REPO_ROOT}/boost_performance.sh"

    for ram in 2 4 8 16 32; do
        RAM_GB="$ram"
        if calculate_profiles >/dev/null 2>&1; then
            ok "profile exists for ${ram}GB"
        else
            not_ok "profile exists for ${ram}GB"
        fi
    done

    RAM_GB=4
    calculate_profiles
    assert_eq "4GB worker_connections" "4096" "$NGINX_WORKER_CONNECTIONS_DEFAULT"
    assert_eq "4GB memory_limit" "384M" "$PHP_MEMORY_LIMIT"
    assert_eq "4GB opcache" "192" "$PHP_OPCACHE_MEM"
    assert_eq "4GB pm.max_children base" "20" "$PHP_PM_MAX_CHILDREN_DEFAULT"

    # Every tier must fit workers plus reserve inside physical RAM.
    for ram in 2 4 8 16 32; do
        RAM_GB="$ram"
        calculate_profiles
        case "$ram" in
            2) reserve=700 ;; 4) reserve=1200 ;; 8) reserve=2000 ;;
            16) reserve=3500 ;; 32) reserve=6000 ;;
        esac
        committed=$((PHP_PM_MAX_CHILDREN_DEFAULT * 110 + reserve))
        total=$((ram * 1024))
        if (( committed < total )); then
            ok "${ram}GB profile fits in RAM (${committed}MB of ${total}MB)"
        else
            not_ok "${ram}GB profile fits in RAM" "< ${total}MB" "${committed}MB"
        fi
    done

)

# ---------------------------------------------------------------------------
section "setup_staging.sh: .env rewriting"
# ---------------------------------------------------------------------------
(
    # shellcheck source=/dev/null
    SETUP_LARAVEL_LIB_ONLY=1 source "${REPO_ROOT}/setup_staging.sh"
    DRY_RUN=0

    env_file="${WORKDIR}/env_basic"
    cat > "$env_file" <<'EOF'
APP_NAME="My App"
APP_ENV=production
APP_DEBUG=false
DB_DATABASE=appdb
DB_PASSWORD="p@ss#word"
MAIL_MAILER=smtp
EOF

    assert_eq "get_env_value reads a plain value" "appdb" "$(get_env_value "$env_file" DB_DATABASE)"
    assert_eq "get_env_value reads a quoted value" "My App" "$(get_env_value "$env_file" APP_NAME)"
    assert_eq "get_env_value on a missing key" "" "$(get_env_value "$env_file" NOPE)"

    set_env_value "$env_file" APP_ENV staging
    assert_eq "set_env_value rewrites in place" "staging" "$(get_env_value "$env_file" APP_ENV)"

    set_env_value "$env_file" BRAND_NEW appended
    assert_eq "set_env_value appends a missing key" "appended" "$(get_env_value "$env_file" BRAND_NEW)"

    # Regression: interpolating the value into a bash -c string broke on quotes.
    set_env_value "$env_file" QUOTED "it's fine"
    assert_eq "set_env_value survives a single quote" "it's fine" "$(get_env_value "$env_file" QUOTED)"

    assert_eq "unrelated keys untouched" "p@ss#word" "$(get_env_value "$env_file" DB_PASSWORD)"

    # set_env_value_if_present must not create keys the app does not use.
    if set_env_value_if_present "$env_file" CACHE_STORE file; then
        not_ok "set_env_value_if_present skips absent keys"
    else
        ok "set_env_value_if_present skips absent keys"
    fi
    assert_eq "absent key was not appended" "" "$(get_env_value "$env_file" CACHE_STORE)"

    if set_env_value_if_present "$env_file" MAIL_MAILER log; then
        ok "set_env_value_if_present rewrites present keys"
    else
        not_ok "set_env_value_if_present rewrites present keys"
    fi
    assert_eq "present key was rewritten" "log" "$(get_env_value "$env_file" MAIL_MAILER)"

)

# ---------------------------------------------------------------------------
section "setup_staging.sh: production isolation defaults"
# ---------------------------------------------------------------------------
(
    # shellcheck source=/dev/null
    SETUP_LARAVEL_LIB_ONLY=1 source "${REPO_ROOT}/setup_staging.sh"
    DRY_RUN=0
    DOMAIN="staging.example.com"
    SRC_PATH="${WORKDIR}/src"
    DEST_PATH="${WORKDIR}/dest"
    mkdir -p "$SRC_PATH" "$DEST_PATH"

    cat > "${SRC_PATH}/.env" <<'EOF'
APP_ENV=production
APP_DEBUG=false
APP_URL=https://example.com
DB_CONNECTION=mysql
DB_DATABASE=appdb
DB_URL=mysql://user:secret@10.0.0.5:3306/appdb
MAIL_MAILER=smtp
CACHE_STORE=redis
SESSION_DRIVER=redis
QUEUE_CONNECTION=redis
REDIS_HOST=10.0.0.6
EOF

    seed_env >/dev/null 2>&1
    dest="${DEST_PATH}/.env"

    assert_eq "APP_ENV becomes staging" "staging" "$(get_env_value "$dest" APP_ENV)"
    assert_eq "APP_DEBUG is off by default" "false" "$(get_env_value "$dest" APP_DEBUG)"
    assert_eq "APP_URL starts on http" "http://staging.example.com" "$(get_env_value "$dest" APP_URL)"
    assert_eq "DB_DATABASE is suffixed" "appdb_staging" "$(get_env_value "$dest" DB_DATABASE)"
    assert_eq "DB_URL is cleared so it cannot override DB_DATABASE" "" "$(get_env_value "$dest" DB_URL)"
    assert_eq "MAIL_MAILER cannot reach real users" "log" "$(get_env_value "$dest" MAIL_MAILER)"
    assert_eq "cache leaves the shared backend" "file" "$(get_env_value "$dest" CACHE_STORE)"
    assert_eq "sessions leave the shared backend" "file" "$(get_env_value "$dest" SESSION_DRIVER)"
    assert_eq "queue cannot feed production workers" "sync" "$(get_env_value "$dest" QUEUE_CONNECTION)"
    assert_eq "source .env is left untouched" "appdb" "$(get_env_value "${SRC_PATH}/.env" DB_DATABASE)"

    # APP_URL must only claim https once a certificate exists.
    SSL_READY=0
    finalize_env >/dev/null 2>&1
    assert_eq "APP_URL stays http when SSL failed" "http://staging.example.com" "$(get_env_value "$dest" APP_URL)"
    SSL_READY=1
    finalize_env >/dev/null 2>&1
    assert_eq "APP_URL upgrades after SSL succeeds" "https://staging.example.com" "$(get_env_value "$dest" APP_URL)"

)

# ---------------------------------------------------------------------------
section "setup_staging.sh: isolation opt-outs"
# ---------------------------------------------------------------------------
(
    # shellcheck source=/dev/null
    SETUP_LARAVEL_LIB_ONLY=1 source "${REPO_ROOT}/setup_staging.sh"
    DRY_RUN=0
    DOMAIN="staging.example.com"
    SRC_PATH="${WORKDIR}/src2"
    DEST_PATH="${WORKDIR}/dest2"
    mkdir -p "$SRC_PATH" "$DEST_PATH"
    cat > "${SRC_PATH}/.env" <<'EOF'
DB_DATABASE=appdb
DB_URL=mysql://user:secret@10.0.0.5:3306/appdb
MAIL_MAILER=smtp
CACHE_STORE=redis
QUEUE_CONNECTION=redis
EOF

    KEEP_DB_CONFIG=1
    KEEP_MAIL=1
    KEEP_SERVICES=1
    APP_DEBUG_ON=1
    seed_env >/dev/null 2>&1
    dest="${DEST_PATH}/.env"

    assert_eq "--keep-db-config preserves DB_DATABASE" "appdb" "$(get_env_value "$dest" DB_DATABASE)"
    assert_contains "--keep-db-config preserves DB_URL" "10.0.0.5" "$(get_env_value "$dest" DB_URL)"
    assert_eq "--keep-mail preserves MAIL_MAILER" "smtp" "$(get_env_value "$dest" MAIL_MAILER)"
    assert_eq "--keep-services preserves CACHE_STORE" "redis" "$(get_env_value "$dest" CACHE_STORE)"
    assert_eq "--keep-services preserves QUEUE_CONNECTION" "redis" "$(get_env_value "$dest" QUEUE_CONNECTION)"
    assert_eq "--debug turns APP_DEBUG on" "true" "$(get_env_value "$dest" APP_DEBUG)"

)

# ---------------------------------------------------------------------------
section "setup_staging.sh: PHP-FPM socket detection"
# ---------------------------------------------------------------------------
(
    # shellcheck source=/dev/null
    SETUP_LARAVEL_LIB_ONLY=1 source "${REPO_ROOT}/setup_staging.sh"

    # A vhost as setup_laravel_nginx_ssl.sh writes it, after Certbot rewrote it.
    SOURCE_VHOST="${WORKDIR}/vhost"
    cat > "$SOURCE_VHOST" <<'EOF'
server {
    server_name example.com;
    root /var/www/app/public;
    location ~ \.php$ {
        fastcgi_pass unix:/var/run/php/php8.4-fpm.sock;
    }
    listen 443 ssl; # managed by Certbot
}
EOF
    assert_eq "socket read from the source vhost" "/var/run/php/php8.4-fpm.sock" "$(detect_fpm_socket)"

    FPM_SOCKET="/var/run/php/php8.3-fpm.sock"
    if [[ -x /usr/bin/php8.3 ]]; then
        assert_eq "php binary derived from socket" "/usr/bin/php8.3" "$(detect_php_binary)"
    else
        ok "php binary derived from socket (skipped: no /usr/bin/php8.3 here)"
    fi

)

# ---------------------------------------------------------------------------
section "setup_staging.sh: input validation (subprocess)"
# ---------------------------------------------------------------------------
# validate_inputs is exercised directly so the coverage does not depend on
# running the suite as root. Each call is wrapped in a subshell because the
# function exits on rejection.
check_validation() {
    local label="$1" expect="$2" project="$3" domain="$4" method="$5" suffix="$6"
    local out
    out="$(
        # shellcheck source=/dev/null
        SETUP_LARAVEL_LIB_ONLY=1 source "${REPO_ROOT}/setup_staging.sh"
        PROJECT="$project"; DOMAIN="$domain"; METHOD="$method"; SUFFIX="$suffix"
        validate_inputs 2>&1
    )" || true
    assert_contains "$label" "$expect" "$out"
}

check_validation "rejects a traversing project name" "Invalid project name" \
    "../etc" "staging.example.com" "auto" "-staging"
check_validation "rejects a project name with a slash" "Invalid project name" \
    "a/b" "staging.example.com" "auto" "-staging"
check_validation "rejects an empty project name" "Invalid project name" \
    "" "staging.example.com" "auto" "-staging"
check_validation "rejects a bare hostname" "Invalid domain" \
    "app" "notadomain" "auto" "-staging"
check_validation "rejects a domain containing a path" "Invalid domain" \
    "app" "example.com/staging" "auto" "-staging"
check_validation "rejects an unknown method" "Invalid --method" \
    "app" "staging.example.com" "sftp" "-staging"
check_validation "rejects an empty suffix" "Suffix must not be empty" \
    "app" "staging.example.com" "auto" ""
check_validation "accepts a valid combination" "" \
    "app" "staging.example.com" "auto" "-staging"

# The full script must still refuse to run unprivileged.
if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    assert_contains "refuses to run without root" "must be run as root" \
        "$("${REPO_ROOT}/setup_staging.sh" -n -p app -d staging.example.com 2>&1)"
else
    ok "refuses to run without root (skipped: running as root)"
fi

assert_contains "--help lists the staging flags" "--keep-services" \
    "$("${REPO_ROOT}/setup_staging.sh" --help 2>&1)"

# ---------------------------------------------------------------------------
section "setup_laravel_nginx_ssl.sh: PHP package repository"
# ---------------------------------------------------------------------------
(
    # shellcheck source=/dev/null
    SETUP_LARAVEL_LIB_ONLY=1 source "${REPO_ROOT}/setup_laravel_nginx_ssl.sh"
    DRY_RUN=0

    OS_RELEASE_FILE="${WORKDIR}/os-release"
    cat > "$OS_RELEASE_FILE" <<'EOF'
PRETTY_NAME="Ubuntu 26.04 LTS"
NAME="Ubuntu"
VERSION_ID="26.04"
VERSION_CODENAME=resolute
ID=ubuntu
EOF
    assert_eq "os_codename reads VERSION_CODENAME" "resolute" "$(os_codename)"

    OS_RELEASE_FILE="${WORKDIR}/missing-os-release"
    assert_eq "os_codename is empty without os-release" "" "$(os_codename)"

    entry="$(php_repo_sources_entry resolute)"
    assert_contains "sources entry targets packages.sury.org" "URIs: https://packages.sury.org/php/" "$entry"
    assert_contains "sources entry uses the release codename" "Suites: resolute" "$entry"
    assert_contains "sources entry is signed by the sury keyring" "Signed-By: /usr/share/keyrings/deb.sury.org-php.gpg" "$entry"
    assert_eq "sources entry never references the PPA" "" "$(grep -i ppa <<<"$entry" || true)"

    # Stale PPA entries from older runs are removed; other sources are kept.
    APT_SOURCES_DIR="${WORKDIR}/sources.list.d"
    mkdir -p "$APT_SOURCES_DIR"
    touch "${APT_SOURCES_DIR}/ondrej-ubuntu-php-resolute.sources" \
          "${APT_SOURCES_DIR}/ondrej-ubuntu-php-noble.list" \
          "${APT_SOURCES_DIR}/ondrej-ubuntu-nginx-noble.list" \
          "${APT_SOURCES_DIR}/docker.list"
    remove_ondrej_ppa >/dev/null
    if [[ ! -e "${APT_SOURCES_DIR}/ondrej-ubuntu-php-resolute.sources" && ! -e "${APT_SOURCES_DIR}/ondrej-ubuntu-php-noble.list" ]]; then
        ok "retired ppa:ondrej/php sources are removed"
    else
        not_ok "retired ppa:ondrej/php sources are removed"
    fi
    if [[ -e "${APT_SOURCES_DIR}/ondrej-ubuntu-nginx-noble.list" && -e "${APT_SOURCES_DIR}/docker.list" ]]; then
        ok "unrelated apt sources are left alone"
    else
        not_ok "unrelated apt sources are left alone"
    fi

    # A dry run must not touch the system: no download, no dpkg, no file written.
    DRY_RUN=1
    OS_RELEASE_FILE="${WORKDIR}/os-release"
    PHP_REPO_SOURCES="${APT_SOURCES_DIR}/php.sources"
    php_repo_publishes() { return 0; }
    out="$(add_php_repository 2>&1)"
    assert_contains "dry run prints the keyring download" "DRY-RUN: curl" "$out"
    assert_contains "dry run prints the keyring install" "DRY-RUN: dpkg -i" "$out"
    assert_contains "dry run shows the sources entry" "Suites: resolute" "$out"
    if [[ ! -e "$PHP_REPO_SOURCES" ]]; then
        ok "dry run does not write php.sources"
    else
        not_ok "dry run does not write php.sources"
    fi

    # A release the repository does not publish for fails before anything changes.
    DRY_RUN=0
    php_repo_publishes() { return 1; }
    out="$(add_php_repository 2>&1)" || true
    assert_contains "unpublished codename is rejected" "no PHP packages for 'resolute'" "$out"
    if [[ ! -e "$PHP_REPO_SOURCES" ]]; then
        ok "rejected codename writes nothing"
    else
        not_ok "rejected codename writes nothing"
    fi

)

# ---------------------------------------------------------------------------
PASS="$(grep -c '^P$' "$TALLY" || true)"
FAIL="$(grep -c '^F$' "$TALLY" || true)"
printf '\n\033[1mResult:\033[0m %d passed, %d failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]] || exit 1
