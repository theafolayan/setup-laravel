#!/bin/bash

LOG_FILE="/var/log/laravel_setup.log"

# Function to log installed components
log_install() {
    echo "$1" >> "$LOG_FILE"
}

# Function to undo installations
undo_install() {
    if [[ -f "$LOG_FILE" ]]; then
        echo "Undoing previous installation..."
        while read -r package; do
            if [[ $package == "nginx" ]]; then
                sudo systemctl stop nginx
                sudo apt-get remove --purge -y nginx
                sudo rm -rf /etc/nginx/sites-available/*
                sudo rm -rf /etc/nginx/sites-enabled/*
            elif [[ $package == "mysql" ]]; then
                sudo systemctl stop mysql
                sudo apt-get remove --purge -y mysql-server mysql-client mysql-common
                sudo rm -rf /var/lib/mysql
            elif [[ $package == "php" ]]; then
                sudo apt-get remove --purge -y php*
            elif [[ $package == "composer" ]]; then
                sudo rm -f /usr/local/bin/composer
            elif [[ $package == "certbot" ]]; then
                sudo apt-get remove --purge -y certbot python3-certbot-nginx
            elif [[ $package == "memcached" ]]; then
                sudo systemctl stop memcached
                sudo apt-get remove --purge -y memcached
            fi
        done < "$LOG_FILE"
        rm -f "$LOG_FILE"
        echo "Previous installation removed. Please rerun the script."
        exit 1
    fi
}

# Check for previous installation and offer to undo
if [[ -f "$LOG_FILE" ]]; then
    echo "A previous installation was detected. Do you want to undo it before continuing? (yes/no)"
    read UNDO
    if [[ "$UNDO" == "yes" ]]; then
        undo_install
    fi
fi

# Prompt for domain name and Laravel repository URL
echo "Enter the domain name for this Laravel app (e.g., example.com):"
read DOMAIN

echo "Enter the GitHub repository URL of your Laravel project:"
read REPO_URL

# Ask if MySQL should be installed locally
echo "Do you want to install MySQL locally? (yes/no)"
read INSTALL_MYSQL

# Update and upgrade the system
echo "Updating system..."
sudo apt-get update -y && sudo apt-get upgrade -y

# Install Nginx
echo "Installing Nginx..."
sudo apt-get install nginx -y
log_install "nginx"

# Install MySQL if user chooses local
if [[ "$INSTALL_MYSQL" == "yes" ]]; then
    echo "Installing MySQL..."
    sudo apt-get install mysql-server -y
    sudo mysql_secure_installation
    log_install "mysql"

    # Set up MySQL database
    echo "Setting up MySQL database..."
    DBNAME="laravel_db"
    DBUSER="laravel_user"
    DBPASS="secure_password"

    sudo mysql -u root -e "CREATE DATABASE ${DBNAME};"
    sudo mysql -u root -e "CREATE USER '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';"
    sudo mysql -u root -e "GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'localhost';"
    sudo mysql -u root -e "FLUSH PRIVILEGES;"
fi

# Install PHP 8.2 and required extensions
echo "Installing PHP 8.2 and required extensions..."
sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update -y
sudo apt-get install -y php8.2 php8.2-fpm php8.2-mysql php8.2-xml php8.2-mbstring php8.2-zip php8.2-curl php8.2-bcmath php8.2-ldap php8.2-memcached php8.2-intl
log_install "php"

# Install Composer globally
echo "Installing Composer..."
curl -sS https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer
log_install "composer"

# Clone Laravel repository
echo "Cloning Laravel repository..."
cd /var/www
git clone $REPO_URL laravel

# Set correct permissions
echo "Setting file permissions..."
sudo chown -R www-data:www-data /var/www/laravel
sudo chmod -R 755 /var/www/laravel

# Configure Laravel environment
echo "Configuring Laravel .env file..."
cd /var/www/laravel
cp .env.example .env
php artisan key:generate

# Set database details in .env if local MySQL is used
if [[ "$INSTALL_MYSQL" == "yes" ]]; then
    sed -i "s/DB_DATABASE=laravel/DB_DATABASE=${DBNAME}/" .env
    sed -i "s/DB_USERNAME=root/DB_USERNAME=${DBUSER}/" .env
    sed -i "s/DB_PASSWORD=/DB_PASSWORD=${DBPASS}/" .env
else
    echo "You opted for a remote MySQL instance. Please configure your .env file manually."
fi

# Install and configure Memcached
echo "Installing and configuring Memcached..."
sudo apt-get install memcached -y
sudo systemctl enable memcached
sudo systemctl start memcached
log_install "memcached"

# Set up Laravel cache driver for Memcached
sed -i "s/CACHE_DRIVER=file/CACHE_DRIVER=memcached/" .env

# Configure Nginx for Laravel
# Configure Nginx for Laravel
echo "Configuring Nginx for Laravel..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"

cat << EOF | sudo tee ${NGINX_CONF}
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/laravel/public;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php\$ {
        include snippets/fastcgi-php.conf;
        fastcgi_pass unix:/var/run/php/php8.2-fpm.sock;
        fastcgi_param SCRIPT_FILENAME \$document_root\$fastcgi_script_name;
        include fastcgi_params;
    }

    location ~ /\.ht {
        deny all;
    }

    error_log /var/log/nginx/${DOMAIN}_error.log;
    access_log /var/log/nginx/${DOMAIN}_access.log;
}
EOF

# Enable Nginx configuration and restart Nginx
sudo ln -s ${NGINX_CONF} /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# Install Certbot and configure SSL
echo "Installing Certbot for Let's Encrypt SSL..."
sudo apt-get install certbot python3-certbot-nginx -y
log_install "certbot"

# Generate SSL certificate
echo "Generating SSL certificate for ${DOMAIN}..."
sudo certbot --nginx -d ${DOMAIN} -d www.${DOMAIN} --non-interactive --agree-tos -m admin@${DOMAIN}

# Configure auto-renewal of SSL certificates
echo "Setting up auto-renewal for SSL certificates..."
sudo systemctl enable certbot.timer
sudo systemctl start certbot.timer

# Restart Nginx and PHP-FPM
echo "Restarting Nginx and PHP-FPM..."
sudo systemctl restart nginx
sudo systemctl restart php8.2-fpm

echo "Laravel app with SSL setup complete."
