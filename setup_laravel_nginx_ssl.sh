#!/bin/bash

# Prompt for domain name and Laravel repository URL
echo "Enter the domain name for this Laravel app (e.g., example.com):"
read DOMAIN

echo "Enter the GitHub repository URL of your Laravel project:"
read REPO_URL

# Update and upgrade the system
echo "Updating system..."
sudo apt-get update -y
sudo apt-get upgrade -y

# Install Nginx
echo "Installing Nginx..."
sudo apt-get install nginx -y

# Install MySQL
echo "Installing MySQL..."
sudo apt-get install mysql-server -y
sudo mysql_secure_installation

# Install PHP 8.2 and required extensions
echo "Installing PHP 8.2 and required extensions..."
sudo add-apt-repository ppa:ondrej/php -y
sudo apt-get update -y
sudo apt-get install php8.2 php8.2-fpm php8.2-mysql php8.2-xml php8.2-mbstring php8.2-zip php8.2-curl php8.2-bcmath php8.2-ldap php8.2-memcached -y

# Install Composer globally
echo "Installing Composer..."
curl -sS https://getcomposer.org/installer | php
sudo mv composer.phar /usr/local/bin/composer

# Set up MySQL database
echo "Setting up MySQL database..."
DBNAME="laravel_db"
DBUSER="laravel_user"
DBPASS="secure_password"

sudo mysql -u root -e "CREATE DATABASE ${DBNAME};"
sudo mysql -u root -e "CREATE USER '${DBUSER}'@'localhost' IDENTIFIED BY '${DBPASS}';"
sudo mysql -u root -e "GRANT ALL PRIVILEGES ON ${DBNAME}.* TO '${DBUSER}'@'localhost';"
sudo mysql -u root -e "FLUSH PRIVILEGES;"

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

sed -i "s/DB_DATABASE=laravel/DB_DATABASE=${DBNAME}/" .env
sed -i "s/DB_USERNAME=root/DB_USERNAME=${DBUSER}/" .env
sed -i "s/DB_PASSWORD=/DB_PASSWORD=${DBPASS}/" .env

# Install and configure Memcached
echo "Installing and configuring Memcached..."
sudo apt-get install memcached -y
sudo systemctl enable memcached
sudo systemctl start memcached

# Set up Laravel cache driver for Memcached
sed -i "s/CACHE_DRIVER=file/CACHE_DRIVER=memcached/" .env

# Configure Nginx for Laravel
echo "Configuring Nginx for Laravel..."
NGINX_CONF="/etc/nginx/sites-available/${DOMAIN}"
sudo bash -c "cat > ${NGINX_CONF} <<EOL
server {
    listen 80;
    server_name ${DOMAIN} www.${DOMAIN};
    root /var/www/laravel/public;

    index index.php index.html index.htm;

    location / {
        try_files \$uri \$uri/ /index.php?\$query_string;
    }

    location ~ \.php$ {
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
EOL"

# Enable Nginx configuration and restart Nginx
sudo ln -s ${NGINX_CONF} /etc/nginx/sites-enabled/
sudo nginx -t
sudo systemctl restart nginx

# Install Certbot and configure SSL
echo "Installing Certbot for Let's Encrypt SSL..."
sudo apt-get install certbot python3-certbot-nginx -y

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

# Push to GitHub repository (optional step)
echo "Do you want to push this project back to the GitHub repository? (y/n)"
read PUSH_TO_REPO

if [ "$PUSH_TO_REPO" = "y" ]; then
    cd /var/www/laravel
    git add .
    git commit -m "Deployed Laravel project with MySQL, PHP 8.2, Nginx, SSL, and Memcached"
    git push origin main
fi

echo "Laravel app with SSL setup complete."
