# Laravel Deployment Automation Script

This repository contains a bash script to automate the deployment of a Laravel application with Nginx, PHP, a selectable database (MySQL or PostgreSQL), optional Memcached, recommended PHP OPcache settings, and SSL on an Ubuntu (or similar) server.

## Prerequisites

Before running this script, ensure that:
- You have root (sudo) access to the Ubuntu server.
- The server is accessible and has an open port for SSH connections.
- You have a domain name configured to point to your server.

## Features

- Installs Nginx, PHP (version selectable) with recommended OPcache configuration, MySQL or PostgreSQL, optional Memcached, and Composer.
- Supports interactive prompts or a fully non-interactive mode using command line flags.
- After the domain is entered, displays the server IP and waits for confirmation that DNS A records for the domain and www subdomain point to it.
- Generates secure random database passwords and secures MySQL without interactive prompts.
- Clones a Laravel project from a specified GitHub repository, installs dependencies with `--no-dev --optimize-autoloader`, and caches configuration, routes, and views for better performance.
- Automatically configures Nginx with gzip and static asset caching, disables the default site, then enables SSL using Let's Encrypt with Certbot.
- Optionally pushes local changes back to the GitHub repository. (Coming Soon)

## How to Use

### Step 1: Copy the Script

SSH into your Ubuntu server and copy the script:

```bash
wget https://raw.githubusercontent.com/theafolayan/setup-laravel/main/setup_laravel_nginx_ssl.sh
```

## Step 2: Make the Script Executable
Make the script executable: 

```bash 
chmod +x setup_laravel_nginx_ssl.sh
```
## Step 3: Run the Script
Run the script with superuser privileges. The script defaults to PHP 8.4 and can run interactively or non-interactively.

Interactive:

```bash
sudo ./setup_laravel_nginx_ssl.sh
```

Non-interactive example:

```bash
sudo ./setup_laravel_nginx_ssl.sh -n \
  -a myapp -d example.com --dns-confirm yes \
  --repo-url https://github.com/laravel/laravel.git \
  --db-choice mysql --db-name appdb --db-user appuser --db-pass secret
```
The script will prompt only for values not supplied via flags when running interactively.

### Help and Flags

View all available options:

```bash
./setup_laravel_nginx_ssl.sh --help
```

| Flag | Description | Default |
|------|-------------|---------|
| `-a`, `--app-name` | Application name | `laravel_app` |
| `-d`, `--domain` | Domain name for the site | `example.com` |
| `--dns-confirm` | Confirm DNS records are in place (`yes`/`no`) | `yes` |
| `--repo-url` | Git repository containing the Laravel project | `https://github.com/laravel/laravel.git` |
| `--db-choice` | Database to install (`mysql`, `postgresql`, or `none`) | `mysql` |
| `--db-name` | Database name | `laravel_db` |
| `--db-user` | Database user | `laravel_user` |
| `--db-pass` | Database password | random |
| `--php-version` | PHP version | `8.4` |
| `-n`, `--non-interactive` | Skip prompts and use provided flags | _disabled_ |
| `--dry-run` | Show commands without executing them | _disabled_ |
| `-h`, `--help` | Display help information | _disabled_ |

Example one-liner including all major flags:

```bash
sudo ./setup_laravel_nginx_ssl.sh -n \
  -a myapp -d example.com --dns-confirm yes \
  --repo-url https://github.com/laravel/laravel.git \
  --db-choice mysql --db-name appdb --db-user appuser --db-pass secret \
  --php-version 8.4 --dry-run
```

The `--dry-run` flag prints the commands that would run, letting you verify your settings without making any system changes.

## Step 4: SSL Setup
The script will automatically configure SSL using Let's Encrypt for the provided domain.

Ensure that your domain DNS is correctly set up to point to the server's IP address. Certbot will handle the SSL setup and configure Nginx to use the certificates.

## Adding Additional Domains

If you need to point extra domains to an existing application, use the `manage_domains.sh` script included in this repository.

### Step 1: Copy the Script

```bash
wget https://raw.githubusercontent.com/theafolayan/setup-laravel/main/manage_domains.sh
chmod +x manage_domains.sh
```

### Step 2: Run the Script

```bash
sudo ./manage_domains.sh
```

The script lists applications found in `/var/www` and lets you choose which one to update. It auto-detects the primary domain and shows any other domains already configured. When prompted, enter additional domain(s) to add. The script updates the Nginx configuration and obtains SSL certificates for the new domains using Certbot.
Make sure DNS A records for the new domain(s) point to your server before running the script. You'll be prompted to type `yes` to confirm the records are in place before the script requests SSL certificates.
