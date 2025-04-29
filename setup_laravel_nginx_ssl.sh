#!/bin/bash

LOG_FILE="/var/log/laravel_setup.log"

# Log installed components
log_install() {
    echo "$1" >> "$LOG_FILE"
}

# Undo a previous installation
undo_install() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "Undoing previous installation..."
        while read -r pkg; do
            case "$pkg" in
                nginx)
                    sudo systemctl stop nginx
                    sudo apt-get remove --purge -y nginx
                    sudo rm -rf /etc/nginx/sites-available/* /etc/nginx/sites-enabled/*
                    ;;
                mysql)
                    sudo systemctl stop mysql
                    sudo apt-get remove --purge -y mysql-server mysql-client mysql-common
                    sudo rm -rf /var/lib/mysql
                    ;;
                postgresql)
                    sudo systemctl stop postgresql
                    sudo apt-get remove --purge -y postgresql postgresql-contrib
                    ;;
                php)
                    sudo apt-get remove --purge -y php*
                    ;;
                composer)
                    sudo rm -f /usr/local/bin/composer
                    ;;
                certbot)
                    sudo apt-get remove --purge -y certbot python3-certbot-nginx
                    ;;
                memcached)
                    sudo systemctl stop memcached
                    sudo apt-get remove --purge -y memcached
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
    echo "A previous installation was detected. Undo it before continuing? (yes/no)"
    read -r UNDO
    [[ "$UNDO" == "yes" ]] && undo_install
fi

# ===== User Prompts =====
echo "Enter your app name (will create /var/www/<app_name>):"
read -r APP_NAME

echo "Enter your domain (e.g. example.com):"
read -r DOMAIN

echo "Enter your Laravel repo URL:"
read -r REPO_URL

echo "Choose local database to install (mysql/postgresql/none):"
read -r DB_CHOICE

# ===== System Update =====
echo "Updating system..."
sudo apt-get update -y && sudo apt-get upgrade -y

# ===== Nginx =====
echo "Installing Nginx..."
sudo apt-get install nginx -y
log_install "nginx"

# ===== Database Installation & Setup =====
DB_DRIVER=""
DB_PORT=""
if [[ "$DB_CHOICE" == "mysql" ]]; then
    echo "Installing MySQL..."
    sudo apt-get install mysql-server -y
    sudo mysql_secure_installation
    log_install "mysql"

    DB_DRIVER="mysql"
    DB_PORT="3306"
    DBNAME="laravel_db"
    DBUSER="laravel_user"
    DBPASS="secure_password"

    echo "Creating MySQL database and user..."
    sudo mysql -u root -e "CREATE DATABASE ${DBNAME};"
    sudo mysql -u root -e "CREATE USER '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';"
    sudo mysql -u root -e "GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'localhost';"
    sudo mysql -u root -e "FLUSH PRIVILEGES;"

elif [[ "$DB_CHOICE" == "postgresql" ]]; then
    echo "Installing PostgreSQL..."
    sudo apt-get install postgresql postgresql-contrib -y
    log_install "postgresql"

    DB_DRIVER="pgsql"
    DB_PORT="5432"
    DBNAME="laravel_db"
    DBUSER="laravel_user"
    DBPASS="secure_password"

    echo "Creating PostgreSQL database and user..."
    sudo -u postgres psql -c "CREATE DATABASE ${DBNAME};"
    sudo -u postgres psql -c "CREATE USER ${DBUSER} WITH PASSWORD '${DBPASS}';"
    sudo -u postgres psql -c "GRANT ALL PRIVILEGES ON DATABASE ${DBNAME} TO ${DBUSER};"

else
    echo "No local database will be installed. You must configure your remote DB manually."
fi

# ===== PHP Version Prompt & Validation =====
echo "Adding PHP PPA and fetching available versions..."
sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update -y

AVAILABLE_VERSIONS=$(apt-cache pkgnames \
    | grep -E '^php[0-9]\.[0-9]+$' \
    | sed 's/php//' \
    | sort -u)

echo "Available PHP versions: $AVAILABLE_VERSIONS"
echo "Which PHP version should we install? (e.g. 7.4, 8.0, 8.1, 8.2)"
read -r PHP_VERSION

while ! echo "$AVAILABLE_VERSIONS" | grep -qx "$PHP_VERSION"; do
    echo "PHP $PHP_VERSION not found. Please choose from: $AVAILABLE_VERSIONS"
    read -r PHP_VERSION
done

# Decide which PHP DB extension to add
PHP_DB_EXT=""
if [[ "$DB_DRIVER" == "mysql" ]]; then
    PHP_DB_EXT="php${PHP_VERSION}-mysql"
elif [[ "$DB_DRIVER" == "pgsql" ]]; then
    PHP_DB_EXT="php${PHP_VERSION}-pgsql"
fi

# ===== Install PHP & Extensions =====
echo "Installing PHP $PHP_VERSION and extensions..."
sudo apt-get install -y \
    php${PHP_VERSION} \
    php${PHP_VERSION}-fpm \
    $PHP_DB_EXT \
    php${PHP_VERSION}-gd \
    php${PHP_VERSION}-xml \
    php${PHP_VERSION}-mbstring \
    php${PHP_VERSION}-zip \
    php${PHP_VERSION}-curl \
    php${PHP_VERSION}-bcmath \
    php${PHP_VERSION}-ldap \
    php${PHP_VERSION}-memcached \
    php${PHP_VERSION}-intl
log_install "php"

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
sudo mv composer.phar /usr/local/bin/composer
log_install "composer"

# ===== Clone & Prepare Laravel =====
echo "Cloning Laravel into /var/www/$APP_NAME..."
sudo mkdir -p /var/www/$APP_NAME
sudo chown "$USER":"$USER" /var/www/$APP_NAME
git clone "$REPO_URL" "/var/www/$APP_NAME"

echo "Setting permissions..."
sudo chown -R www-data:www-data "/var/www/$APP_NAME"
sudo chmod -R 755 "/var/www/$APP_NAME"

cd "/var/www/$APP_NAME"
cp .env.example .env
php artisan key:generate

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

# ===== Memcached =====
echo "Installing Memcached..."
sudo apt-get install memcached -y
sudo systemctl enable --now memcached
log_install "memcached"
sed -i "s/^CACHE_DRIVER=.*/CACHE_DRIVER=memcached/" .env

# ===== Nginx Virtual Host =====
echo "Configuring Nginx..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
sudo tee "$NGINX_CONF" > /dev/null <<EOF
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/${APP_NAME}/public;
    index index.php index.html;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
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

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t && sudo systemctl restart nginx

# ===== SSL via Certbot =====
echo "Installing Certbot..."
sudo apt-get install certbot python3-certbot-nginx -y
log_install "certbot"
sudo certbot --nginx \
    -d "${DOMAIN}" -d "www.${DOMAIN}" \
    --non-interactive --agree-tos -m "admin@${DOMAIN}"
sudo systemctl enable --now certbot.timer

# ===== Restart PHP-FPM =====
echo "Restarting $FPM_SERVICE..."
sudo systemctl restart "$FPM_SERVICE"

echo "✅ Deployment complete! /var/www/$APP_NAME running on PHP $PHP_VERSION with GD support."
