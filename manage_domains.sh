#!/bin/bash
set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "This script must be run as root."
    exit 1
fi

# List available applications
if [[ ! -d /var/www ]]; then
    echo "/var/www does not exist."
    exit 1
fi

mapfile -t APPS < <(find /var/www -mindepth 1 -maxdepth 1 -type d -printf "%f\n")
if [[ ${#APPS[@]} -eq 0 ]]; then
    echo "No applications found in /var/www."
    exit 1
fi

echo "Select the application to manage:"
select APP_NAME in "${APPS[@]}"; do
    [[ -n "$APP_NAME" ]] && break
    echo "Invalid selection."
done

read -rp "Enter the primary domain configured for $APP_NAME: " PRIMARY_DOMAIN
NGINX_CONF="/etc/nginx/sites-available/${PRIMARY_DOMAIN}"
if [[ ! -f "$NGINX_CONF" ]]; then
    echo "Nginx config $NGINX_CONF not found."
    exit 1
fi

read -rp "Enter additional domain(s) to add (space-separated): " NEW_DOMAINS

DOMAIN_ARGS=("$PRIMARY_DOMAIN" "www.$PRIMARY_DOMAIN")
NEW_ENTRIES=""
for d in $NEW_DOMAINS; do
    DOMAIN_ARGS+=("$d" "www.$d")
    NEW_ENTRIES+=" $d www.$d"
done

# Update server_name line
sed -i "/server_name/s/;/${NEW_ENTRIES};/" "$NGINX_CONF"

nginx -t && systemctl reload nginx

# Confirm DNS has been updated before requesting certificates
echo "Ensure the following domains point to this server: $NEW_DOMAINS"
read -rp "Type 'yes' once DNS records have propagated: " CONFIRM
if [[ $CONFIRM != "yes" ]]; then
    echo "Aborting SSL certificate request."
    exit 1
fi

# Request certificates for all domains
CERTBOT_ARGS=()
for d in "${DOMAIN_ARGS[@]}"; do
    CERTBOT_ARGS+=(-d "$d")
done
certbot --nginx --non-interactive --agree-tos -m "admin@${PRIMARY_DOMAIN}" "${CERTBOT_ARGS[@]}"

echo "Added domains: $NEW_DOMAINS to $PRIMARY_DOMAIN"
