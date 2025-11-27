#!/usr/bin/env bash
set -euo pipefail

LOG_FILE="/var/log/laravel_setup.log"
NON_INTERACTIVE=0
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: setup_laravel_nginx_ssl.sh [options]
  -a, --app-name NAME         Application name
  -d, --domain DOMAIN         Domain name
      --dns-confirm yes|no    Confirm DNS setup
      --repo-url URL          Laravel repository URL
      --db-choice CHOICE      mysql|postgresql|none
      --db-name NAME          Database name
      --db-user USER          Database user
      --db-pass PASS          Database password
      --php-version VERSION   PHP version (default 8.4)
      --supervisor yes|no     Install Supervisor queue worker (default no)
  -n, --non-interactive       Do not prompt for input
      --dry-run               Show commands without executing
  -h, --help                  Show this message
EOF
}

log() {
    echo "[$(date +'%T')] $1"
}

prompt_if_unset() {
    local var="$1" prompt="$2" default="$3"
    declare -n ref=$var
    if [[ -z ${ref:-} && $NON_INTERACTIVE -eq 0 ]]; then
        read -rp "$prompt [$default]: " ref
    fi
    ref=${ref:-$default}
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -a|--app-name) APP_NAME="$2"; shift 2;;
        -d|--domain) DOMAIN="$2"; shift 2;;
        --dns-confirm) DNS_CONFIRM="$2"; shift 2;;
        --repo-url) REPO_URL="$2"; shift 2;;
        --db-choice) DB_CHOICE="$2"; shift 2;;
        --db-name) DBNAME="$2"; shift 2;;
        --db-user) DBUSER="$2"; shift 2;;
        --db-pass) DBPASS="$2"; shift 2;;
        --php-version) PHP_VERSION="$2"; shift 2;;
        --supervisor) INSTALL_SUPERVISOR="$2"; shift 2;;
        -n|--non-interactive) NON_INTERACTIVE=1; shift;;
        --dry-run) DRY_RUN=1; shift;;
        -h|--help) usage; exit 0;;
        *) echo "Unknown option: $1"; usage; exit 1;;
    esac
done

if [[ $DRY_RUN -eq 1 ]]; then
    shopt -s expand_aliases
    for cmd in apt-get systemctl git composer curl mv cp sed ln rm nginx certbot php add-apt-repository tee mysql psql sudo openssl supervisorctl; do
        # shellcheck disable=SC2139
        alias "$cmd"="echo DRY-RUN: $cmd"
    done
fi

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# Log installed components
log_install() {
    echo "$1" >> "$LOG_FILE"
}

# Undo a previous installation
undo_install() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "Undoing previous installation..."
        while IFS= read -r pkg; do
            case "$pkg" in
                nginx)
                    systemctl stop nginx || true
                    apt-get remove --purge -y nginx
                    rm -rf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*
                    ;;
                mysql)
                    systemctl stop mysql || true
                    apt-get remove --purge -y mysql-server mysql-client mysql-common
                    rm -rf /var/lib/mysql
                    ;;
                postgresql)
                    systemctl stop postgresql || true
                    apt-get remove --purge -y postgresql postgresql-contrib
                    ;;
                php)
                    apt-get remove --purge -y php*
                    ;;
                composer)
                    rm -f /usr/local/bin/composer
                    ;;
                certbot)
                    apt-get remove --purge -y certbot python3-certbot-nginx
                    ;;
                memcached)
                    systemctl stop memcached || true
                    apt-get remove --purge -y memcached
                    ;;
                supervisor)
                    systemctl stop supervisor || true
                    apt-get remove --purge -y supervisor
                    ;;
                app_path:*)
                    path=${pkg#app_path:}
                    rm -rf "$path"
                    ;;
                nginx_conf:*)
                    conf=${pkg#nginx_conf:}
                    rm -f "$conf" "/etc/nginx/sites-enabled/$(basename "$conf")"
                    ;;
                supervisor_conf:*)
                    conf=${pkg#supervisor_conf:}
                    rm -f "$conf"
                    if command -v supervisorctl >/dev/null 2>&1; then
                        supervisorctl reread || true
                        supervisorctl update || true
                    fi
                    ;;
                ssl_domain:*)
                    domain=${pkg#ssl_domain:}
                    rm -rf "/etc/letsencrypt/live/$domain" "/etc/letsencrypt/archive/$domain" "/etc/letsencrypt/renewal/$domain.conf"
                    ;;
            esac
        done < "$LOG_FILE"
        rm -f "$LOG_FILE"
        echo "Previous installation removed. Please rerun the script."
        exit 1
    fi
}

# Offer to undo if log exists
if [[ -f "$LOG_FILE" ]]; then
    if [[ $NON_INTERACTIVE -eq 1 ]]; then
        log "Previous installation detected; remove $LOG_FILE to start fresh."
    else
        echo "A previous installation was detected. Undo it before continuing? (yes/no)"
        read -r UNDO
        [[ "$UNDO" == "yes" ]] && undo_install
    fi
fi

# ===== User Prompts =====
prompt_if_unset APP_NAME "Enter your app name (will create /var/www/<app_name>)" "laravel_app"
prompt_if_unset DOMAIN "Enter your domain (e.g. example.com)" "example.com"

# Show server IP and confirm DNS records
SERVER_IP=$(curl -4 -s ifconfig.co || hostname -I | awk '{print $1}')
log "Please point A records for ${DOMAIN} and www.${DOMAIN} to ${SERVER_IP}."
prompt_if_unset DNS_CONFIRM "Have you updated the DNS records? (yes/no)" "yes"
if [[ "$DNS_CONFIRM" != "yes" ]]; then
    log "DNS records not confirmed. Aborting."
    exit 1
fi

prompt_if_unset REPO_URL "Enter your Laravel repo URL" "https://github.com/laravel/laravel.git"

while true; do
    prompt_if_unset DB_CHOICE "Choose local database to install (mysql/postgresql/none)" "mysql"
    case "$DB_CHOICE" in
        mysql|postgresql|none) break ;;
        *) if [[ $NON_INTERACTIVE -eq 1 ]]; then
               log "Invalid DB choice: $DB_CHOICE"; exit 1
           else
               echo "Invalid choice. Please enter mysql, postgresql, or none."
           fi ;;
    esac
done

if [[ "$DB_CHOICE" == "mysql" || "$DB_CHOICE" == "postgresql" ]]; then
    prompt_if_unset DBNAME "Database name" "laravel_db"
    prompt_if_unset DBUSER "Database username" "laravel_user"
    default_pass=$(openssl rand -base64 16)
    prompt_if_unset DBPASS "Database password" "$default_pass"
fi

# ===== System Update =====
log "Updating package lists..."
apt-get update -y
prompt_if_unset RUN_UPGRADE "Run full system upgrade? (yes/no)" "no"
if [[ "$RUN_UPGRADE" == "yes" ]]; then
    apt-get upgrade -y
fi

# ===== Nginx =====
log "Installing Nginx..."
apt-get install nginx -y
log_install "nginx"

# ===== Database Installation & Setup =====
DB_DRIVER=""
DB_PORT=""
if [[ "$DB_CHOICE" == "mysql" ]]; then
    echo "Installing MySQL..."
    apt-get install mysql-server -y
    log_install "mysql"

    DB_DRIVER="mysql"
    DB_PORT="3306"
    MYSQL_ROOT_PASS=$(openssl rand -base64 16)

    mysql --user=root <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY '${MYSQL_ROOT_PASS}';
DELETE FROM mysql.user WHERE User='';
DROP DATABASE IF EXISTS test;
DELETE FROM mysql.db WHERE Db='test' OR Db='test\\_%';
FLUSH PRIVILEGES;
SQL

    echo "Creating MySQL database and user..."
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "CREATE DATABASE ${DBNAME};"
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "CREATE USER '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';"
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'localhost';"
    mysql -uroot -p"${MYSQL_ROOT_PASS}" -e "FLUSH PRIVILEGES;"
    echo "MySQL root password: ${MYSQL_ROOT_PASS}"
    echo "Database ${DBNAME} and user ${DBUSER} created with password ${DBPASS}"

elif [[ "$DB_CHOICE" == "postgresql" ]]; then
    echo "Installing PostgreSQL..."
    apt-get install postgresql postgresql-contrib -y
    log_install "postgresql"

    DB_DRIVER="pgsql"
    DB_PORT="5432"

    echo "Creating PostgreSQL database and user..."
    runuser -u postgres -- psql -c "CREATE DATABASE ${DBNAME};"
    runuser -u postgres -- psql -c "CREATE USER ${DBUSER} WITH PASSWORD '${DBPASS}';"
    runuser -u postgres -- psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DBNAME} TO ${DBUSER};"
    echo "Database ${DBNAME} and user ${DBUSER} created with password ${DBPASS}"

else
    echo "No local database will be installed. You must configure your remote DB manually."
fi

# ===== PHP Version Prompt & Validation =====
log "Adding PHP PPA and fetching available versions..."
add-apt-repository ppa:ondrej/php -y
apt-get update -y

AVAILABLE_VERSIONS=$(apt-cache pkgnames \
    | grep -E '^php[0-9]\.[0-9]+$' \
    | sed 's/php//' \
    | sort -u)

prompt_if_unset PHP_VERSION "Which PHP version should we install? ($AVAILABLE_VERSIONS)" "8.4"
if ! echo "$AVAILABLE_VERSIONS" | grep -qx "$PHP_VERSION"; then
    log "PHP $PHP_VERSION not found. Available: $AVAILABLE_VERSIONS"
    exit 1
fi

# Decide which PHP DB extension to add
PHP_DB_EXT=""
if [[ "$DB_DRIVER" == "mysql" ]]; then
    PHP_DB_EXT="php${PHP_VERSION}-mysql"
elif [[ "$DB_DRIVER" == "pgsql" ]]; then
    PHP_DB_EXT="php${PHP_VERSION}-pgsql"
fi

# ===== Install PHP & Extensions =====
echo "Installing PHP $PHP_VERSION and extensions..."
apt-get install -y \
    "php${PHP_VERSION}" \
    "php${PHP_VERSION}-fpm" \
    "php${PHP_VERSION}-opcache" \
    "$PHP_DB_EXT" \
    "php${PHP_VERSION}-gd" \
    "php${PHP_VERSION}-xml" \
    "php${PHP_VERSION}-mbstring" \
    "php${PHP_VERSION}-zip" \
    "php${PHP_VERSION}-curl" \
    "php${PHP_VERSION}-bcmath" \
    "php${PHP_VERSION}-ldap" \
    "php${PHP_VERSION}-memcached" \
    "php${PHP_VERSION}-intl"
log_install "php"

# ===== Configure PHP OPcache =====
echo "Applying recommended OPcache settings..."
OPCACHE_INI="/etc/php/${PHP_VERSION}/fpm/conf.d/99-opcache-recommended.ini"
tee "$OPCACHE_INI" > /dev/null <<'EOF'
opcache.enable=1
opcache.enable_cli=1
opcache.memory_consumption=128
opcache.interned_strings_buffer=8
opcache.max_accelerated_files=10000
opcache.revalidate_freq=2
opcache.validate_timestamps=1
EOF


# ===== Detect PHP-FPM Service =====
FPM_SERVICE="php${PHP_VERSION}-fpm"
if ! systemctl list-unit-files | grep -q "^${FPM_SERVICE}\.service"; then
    ALT=$(systemctl list-unit-files \
          | grep -oP '^php.*-fpm\.service' \
          | head -n1 \
          | sed 's/\.service$//')
    if [[ -n "$ALT" ]]; then
        echo "Warning: ${FPM_SERVICE}.service not found. Falling back to ${ALT}.service"
        FPM_SERVICE="$ALT"
    else
        echo "Error: Could not find any php-fpm service. Aborting."
        exit 1
    fi
fi
echo "Using PHP-FPM service: $FPM_SERVICE"

# ===== Composer =====
echo "Installing Composer..."
curl -sS https://getcomposer.org/installer | php
mv composer.phar /usr/local/bin/composer
log_install "composer"

# ===== Clone & Prepare Laravel =====
echo "Cloning Laravel into /var/www/$APP_NAME..."
mkdir -p "/var/www/$APP_NAME"
git clone "$REPO_URL" "/var/www/$APP_NAME"

cd "/var/www/$APP_NAME"
composer install --no-interaction --prefer-dist --no-dev --optimize-autoloader
cp .env.example .env
php artisan key:generate

find . -type f -exec chmod 644 {} \;
find . -type d -exec chmod 755 {} \;
chmod -R ug+rwx storage bootstrap/cache
chown -R www-data:www-data "/var/www/$APP_NAME"
log_install "app_path:/var/www/$APP_NAME"

# ===== Configure .env =====
if [[ -n "$DB_DRIVER" ]]; then
    sed -i "s/^DB_CONNECTION=.*/DB_CONNECTION=${DB_DRIVER}/" .env
    sed -i "s/^DB_PORT=.*/DB_PORT=${DB_PORT}/" .env
    sed -i "s/^DB_DATABASE=.*/DB_DATABASE=${DBNAME}/" .env
    sed -i "s/^DB_USERNAME=.*/DB_USERNAME=${DBUSER}/" .env
    sed -i "s/^DB_PASSWORD=.*/DB_PASSWORD=${DBPASS}/" .env
else
    echo "Remember to set DB_CONNECTION, DB_HOST, DB_PORT, DB_DATABASE, DB_USERNAME, DB_PASSWORD in .env."
fi

# ===== Supervisor Prompt =====
while true; do
    prompt_if_unset INSTALL_SUPERVISOR "Install Supervisor to manage Laravel queue workers? (yes/no)" "no"
    case "$INSTALL_SUPERVISOR" in
        yes|no) break ;;
        *) if [[ $NON_INTERACTIVE -eq 1 ]]; then
               log "Invalid Supervisor choice: $INSTALL_SUPERVISOR"; exit 1
           else
               echo "Invalid choice. Please enter yes or no."
           fi ;;
    esac
done

# ===== Memcached =====
prompt_if_unset INSTALL_MEMCACHED "Install Memcached for caching? (yes/no)" "no"
if [[ "$INSTALL_MEMCACHED" == "yes" ]]; then
    log "Installing Memcached..."
    apt-get install memcached -y
    systemctl enable --now memcached
    log_install "memcached"
    sed -i "s/^CACHE_DRIVER=.*/CACHE_DRIVER=memcached/" .env
else
    log "Skipping Memcached installation."
fi

# ===== Supervisor Setup =====
if [[ "$INSTALL_SUPERVISOR" == "yes" ]]; then
    log "Installing Supervisor and configuring queue worker..."
    apt-get install supervisor -y
    systemctl enable --now supervisor
    log_install "supervisor"

    SUPERVISOR_CONF="/etc/supervisor/conf.d/${APP_NAME}-queue.conf"
    PHP_BINARY="/usr/bin/php${PHP_VERSION}"
    if [[ ! -x "$PHP_BINARY" ]]; then
        PHP_BINARY=$(command -v php)
    fi

    tee "$SUPERVISOR_CONF" > /dev/null <<EOF
[program:${APP_NAME}-queue]
process_name=%(program_name)s_%(process_num)02d
command=${PHP_BINARY} /var/www/${APP_NAME}/artisan queue:work --tries=3 --sleep=3
autostart=true
autorestart=true
user=www-data
numprocs=1
redirect_stderr=true
stdout_logfile=/var/log/supervisor/${APP_NAME}-queue.log
stopwaitsecs=3600
directory=/var/www/${APP_NAME}
EOF

    supervisorctl reread
    supervisorctl update
    supervisorctl enable "${APP_NAME}-queue" || true
    log_install "supervisor_conf:${SUPERVISOR_CONF}"
else
    log "Skipping Supervisor installation."
fi

# ===== Laravel Caching =====
echo "Caching Laravel config, routes and views..."
php artisan config:cache
php artisan route:cache
php artisan view:cache

# ===== Nginx Virtual Host =====
echo "Configuring Nginx..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/${APP_NAME}/public;
    index index.php index.html;

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
        fastcgi_pass unix:/var/run/php/${FPM_SERVICE}.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
    access_log /var/log/nginx/${DOMAIN}_access.log;
    error_log  /var/log/nginx/${DOMAIN}_error.log;
}
EOF

ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
if [[ -e /etc/nginx/sites-enabled/default ]]; then
    rm /etc/nginx/sites-enabled/default
fi
nginx -t && systemctl restart nginx
log_install "nginx_conf:${NGINX_CONF}"

# ===== SSL via Certbot =====
echo "Installing Certbot..."
apt-get install certbot python3-certbot-nginx -y
log_install "certbot"
certbot --nginx \
    -d "${DOMAIN}" -d "www.${DOMAIN}" \
    --non-interactive --agree-tos -m "admin@${DOMAIN}"
systemctl enable --now certbot.timer
log_install "ssl_domain:${DOMAIN}"

# ===== Restart PHP-FPM =====
echo "Restarting $FPM_SERVICE..."
systemctl restart "$FPM_SERVICE"

echo "✅ Deployment complete! /var/www/$APP_NAME running on PHP $PHP_VERSION with GD support."
