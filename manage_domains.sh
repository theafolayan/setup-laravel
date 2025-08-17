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

# Detect the primary domain from the Nginx configuration
PRIMARY_CONF=$(grep -Rls "root /var/www/${APP_NAME}/public;" /etc/nginx/sites-available | head -n1 || true)
if [[ -z "$PRIMARY_CONF" ]]; then
    echo "Could not detect primary domain for $APP_NAME"
    exit 1
fi
NGINX_CONF="$PRIMARY_CONF"
PRIMARY_DOMAIN=$(basename "$NGINX_CONF")

# Extract existing domains from server_name (exclude primary and www)
SERVER_NAMES=$(grep -E "^\s*server_name" "$NGINX_CONF" | sed -E 's/^\s*server_name\s+([^;]+);/\1/')
EXISTING_DOMAINS=()
for name in $SERVER_NAMES; do
    base=${name#www.}
    if [[ "$base" != "$PRIMARY_DOMAIN" && " ${EXISTING_DOMAINS[*]} " != *" $base "* ]]; then
        EXISTING_DOMAINS+=("$base")
    fi
done

if [[ ${#EXISTING_DOMAINS[@]} -gt 0 ]]; then
    echo "Other domains already configured: ${EXISTING_DOMAINS[*]}"
fi

read -rp "${PRIMARY_DOMAIN} is already configured for this installation, add extra domains? " -a NEW_DOMAIN_ARR

if [[ ${#NEW_DOMAIN_ARR[@]} -eq 0 ]]; then
    echo "No additional domains provided."
    exit 0
fi

DOMAIN_ARGS=("$PRIMARY_DOMAIN" "www.$PRIMARY_DOMAIN")
NEW_ENTRIES=""
for d in "${NEW_DOMAIN_ARR[@]}"; do
    DOMAIN_ARGS+=("$d" "www.$d")
    NEW_ENTRIES+=" $d www.$d"
done

# Update server_name line
sed -i "/server_name/s/;/${NEW_ENTRIES};/" "$NGINX_CONF"

nginx -t && systemctl reload nginx

# Confirm DNS has been updated before requesting certificates
echo "Ensure the following domains point to this server: ${NEW_DOMAIN_ARR[*]}"
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
certbot --nginx --non-interactive --agree-tos --expand -m "admin@${PRIMARY_DOMAIN}" "${CERTBOT_ARGS[@]}"

ALL_DOMAINS=("$PRIMARY_DOMAIN" "${EXISTING_DOMAINS[@]}" "${NEW_DOMAIN_ARR[@]}")
echo "Installation domains: ${ALL_DOMAINS[*]}"
