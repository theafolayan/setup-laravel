#!/bin/bash

LOG_FILE="/var/log/laravel_setup.log"

log_install() {
    echo "$1" >> "$LOG_FILE"
}

undo_install() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "Undoing previous installation..."
        while read -r package; do
            case "$package" in
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

[[ -f "$LOG_FILE" ]] && {
    echo "A previous installation was detected. Undo it before continuing? (yes/no)"
    read -r UNDO
    [[ "$UNDO" == "yes" ]] && undo_install
}

# Ask for PHP version, domain, repo and app name
echo "Which PHP version should we install? (e.g. 7.4, 8.0, 8.1, 8.2)"
read -r PHP_VERSION

echo "Enter your app name (will create /var/www/<app_name>):"
read -r APP_NAME

echo "Enter your domain (e.g. example.com):"
read -r DOMAIN

echo "Enter your Laravel repo URL:"
read -r REPO_URL

echo "Install MySQL locally? (yes/no)"
read -r INSTALL_MYSQL

# Update
echo "Updating system..."
sudo apt-get update -y && sudo apt-get upgrade -y

# Nginx
echo "Installing Nginx..."
sudo apt-get install nginx -y
log_install "nginx"

# MySQL
if [[ "$INSTALL_MYSQL" == "yes" ]]; then
    echo "Installing MySQL..."
    sudo apt-get install mysql-server -y
    sudo mysql_secure_installation
    log_install "mysql"

    DBNAME="laravel_db"
    DBUSER="laravel_user"
    DBPASS="secure_password"
    sudo mysql -u root -e "CREATE DATABASE ${DBNAME};"
    sudo mysql -u root -e "CREATE USER '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';"
    sudo mysql -u root -e "GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'localhost';"
    sudo mysql -u root -e "FLUSH PRIVILEGES;"
fi

# PHP
echo "Installing PHP $PHP_VERSION and extensions..."
sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update -y
sudo apt-get install -y \
    php${PHP_VERSION} php${PHP_VERSION}-fpm php${PHP_VERSION}-mysql \
    php${PHP_VERSION}-xml php${PHP_VERSION}-mbstring php${PHP_VERSION}-zip \
    php${PHP_VERSION}-curl php${PHP_VERSION}-bcmath php${PHP_VERSION}-ldap \
    php${PHP_VERSION}-memcached php${PHP_VERSION}-intl
log_install "php"

# Composer
echo "Installing Composer..."
curl -sS https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
log_install "composer"

# Clone Laravel into app directory
echo "Cloning Laravel into /var/www/$APP_NAME..."
sudo mkdir -p /var/www/$APP_NAME
sudo chown "$USER":"$USER" /var/www/$APP_NAME
git clone "$REPO_URL" "/var/www/$APP_NAME"

# Permissions
echo "Setting file permissions..."
sudo chown -R www-data:www-data "/var/www/$APP_NAME"
sudo chmod -R 755 "/var/www/$APP_NAME"

# .env setup
cd "/var/www/$APP_NAME"
cp .env.example .env
php artisan key:generate

if [[ "$INSTALL_MYSQL" == "yes" ]]; then
    sed -i "s/DB_DATABASE=laravel/DB_DATABASE=${DBNAME}/" .env
    sed -i "s/DB_USERNAME=root/DB_USERNAME=${DBUSER}/" .env
    sed -i "s/DB_PASSWORD=/DB_PASSWORD=${DBPASS}/" .env
else
    echo "Remote DB chosen—edit .env manually."
fi

# Memcached
echo "Installing Memcached..."
sudo apt-get install memcached -y
sudo systemctl enable --now memcached
log_install "memcached"
sed -i "s/CACHE_DRIVER=file/CACHE_DRIVER=memcached/" .env

# Nginx config
echo "Configuring Nginx for Laravel..."
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
        fastcgi_pass unix:/var/run/php/php${PHP_VERSION}-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht { deny all; }
    error_log /var/log/nginx/${DOMAIN}_error.log;
    access_log /var/log/nginx/${DOMAIN}_access.log;
}
EOF

sudo ln -sf "$NGINX_CONF" /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# SSL
echo "Installing Certbot..."
sudo apt-get install certbot python3-certbot-nginx -y
log_install "certbot"
sudo certbot --nginx -d "${DOMAIN}" -d "www.${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}"
sudo systemctl enable --now certbot.timer

# Restart services
sudo systemctl restart nginx
sudo systemctl restart php${PHP_VERSION}-fpm

echo "Deployment complete: /var/www/$APP_NAME running on PHP $PHP_VERSION."
