# Laravel Deployment Automation Script

This repository contains a bash script to automate the deployment of a Laravel application with Nginx, PHP, a selectable database (MySQL or PostgreSQL), optional Memcached, optional Supervisor-managed queue workers, recommended PHP OPcache settings, and SSL on an Ubuntu (or similar) server.

## Prerequisites

Before running this script, ensure that:
- You have root (sudo) access to the Ubuntu server.
- The server is accessible and has an open port for SSH connections.
- You have a domain name configured to point to your server.

## Features

- Installs Nginx, PHP (version selectable) with recommended OPcache configuration, MySQL or PostgreSQL, optional Memcached, optional Supervisor queue workers, and Composer.
- Supports interactive prompts or a fully non-interactive mode using command line flags.
- After the domain is entered, displays the server IP and waits for confirmation that DNS A records for the domain and www subdomain point to it.
- Generates secure random database passwords and secures MySQL without interactive prompts.
- Clones a Laravel project from a specified GitHub repository, installs dependencies with `--no-dev --optimize-autoloader`, and caches configuration, routes, and views for better performance.
- Configures a cron job to run `php artisan schedule:run` every minute as `www-data`, logging to `storage/logs/scheduler.log`.
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
| `--supervisor` | Install Supervisor and configure a queue worker (`yes`/`no`) | `no` |
| `-n`, `--non-interactive` | Skip prompts and use provided flags | _disabled_ |
| `--dry-run` | Show commands without executing them | _disabled_ |
| `-h`, `--help` | Display help information | _disabled_ |

When `--supervisor yes` is provided, the script installs Supervisor, writes `/etc/supervisor/conf.d/<app>-queue.conf` to run `php<version> /var/www/<app>/artisan queue:work --tries=3 --sleep=3` as `www-data`, and reloads Supervisor so the worker starts automatically.

Example one-liner including all major flags:

```bash
sudo ./setup_laravel_nginx_ssl.sh -n \
  -a myapp -d example.com --dns-confirm yes \
  --repo-url https://github.com/laravel/laravel.git \
  --db-choice mysql --db-name appdb --db-user appuser --db-pass secret \
  --php-version 8.4 --supervisor yes --dry-run
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

## Creating a Staging Copy

`setup_staging.sh` clones an app that is already deployed in `/var/www` into a sibling
staging copy, reuses the same Nginx and PHP-FPM configuration, and issues SSL for the
staging domain. The staging `.env` is copied from the source so you only have to tweak
credentials afterwards.

### Step 1: Copy the Script

```bash
wget https://raw.githubusercontent.com/theafolayan/setup-laravel/main/setup_staging.sh
chmod +x setup_staging.sh
```

### Step 2: Run the Script

```bash
sudo ./setup_staging.sh -p mytherapistng -d staging.mytherapist.ng
```

That clones `/var/www/mytherapistng` into `/var/www/mytherapistng-staging` and serves it
at `https://staging.mytherapist.ng`. Both flags are prompted for when omitted, and with no
`-p` you get a menu of the apps found in `/var/www`.

What it does:

- Clones from the source app's `origin` remote on the branch the source has checked out,
  falling back to a file copy when the source is not a git repository.
- Copies `.env` from the source, then sets `APP_ENV=staging`, `APP_DEBUG=true`,
  `APP_URL`, and generates a **fresh `APP_KEY`** so staging sessions and encrypted values
  stay separate from production.
- Reuses the PHP-FPM socket detected from the source app's vhost, so staging runs on the
  same PHP version as production.
- Writes an Nginx vhost matching the production template plus a `noindex` header, then
  runs Certbot with `--redirect`.
- Leaves the config **uncached** on purpose, so the `.env` edits you make next take effect.

### Safety defaults

A freshly cloned staging site is live on a public domain before you have had a chance to
edit anything, so two values are pointed somewhere inert by default:

| Default | Why | Opt out |
|---------|-----|---------|
| `DB_DATABASE` becomes `<name>_staging` | Stops staging writing to the production database | `--keep-db-config` |
| `MAIL_MAILER` becomes `log` | Stops staging emailing real users | `--keep-mail` |
| No scheduler or queue worker | Stops background jobs firing against production data | `--scheduler`, `--queue` |

The staging database is **not created** — the script prints the `CREATE DATABASE` command
to run once you have set the credentials you want.

If `nginx -t` fails on the generated vhost it is unlinked again immediately, so a bad
staging config can never take down the other sites on the same server. A Certbot failure
is also non-fatal: the site stays up on HTTP and the retry command is printed.

### Key options

- `-p`, `--project NAME`: existing folder in `/var/www` (prompted, or chosen from a menu).
- `-d`, `--domain DOMAIN`: staging domain, e.g. `staging.example.com`.
- `--suffix SUFFIX`: staging folder suffix (default `-staging`).
- `--branch BRANCH`: branch to clone instead of the one checked out in the source.
- `--method auto|git|copy`: force a git clone or a plain file copy.
- `--with-storage`: copy `storage/app` from the source (production uploads).
- `--with-www`: also request a certificate for `www.<domain>`.
- `--force`: move an existing staging folder aside (timestamped, never deleted) and rebuild.
- `--skip-ssl`, `--dev`, `--dry-run`, `-n`.

Run `./setup_staging.sh --help` for the full list.

## Boosting Performance

After deployment, you can tune Nginx and PHP-FPM for the server size running your Laravel app using `boost_performance.sh`. The script creates backups before modifying configuration files and can run in dry-run or non-interactive modes.

Install the script on your server (same directory as the other helper scripts) and make it executable:

```bash
wget https://raw.githubusercontent.com/theafolayan/setup-laravel/main/boost_performance.sh
chmod +x boost_performance.sh
```

```bash
sudo ./boost_performance.sh --ram-gb 8
```

Key options:

- `--ram-gb 2|4|8|16|32`: Required memory profile. When omitted, you will be prompted (defaults to `8`).
- `--php-mem-per-child-mb N`: Estimated MB per PHP-FPM worker (defaults to `110`, tuned for Laravel workloads).
- `--php-max-children N`: Manually set `pm.max_children` instead of letting the script auto-calculate from memory.
- `--nginx-worker-connections N`: Override the default Nginx worker connections for the selected profile.
- `--skip-ulimits`: Skip raising file descriptor limits via systemd overrides.
- `--dry-run`: Print planned changes without applying them.

### Memory Profiles

Each profile sets a baseline; `pm.max_children` is then lowered if the RAM left after the reserve cannot support it (`(RAM - reserve) / --php-mem-per-child-mb`), so the values below are upper bounds.

| RAM | `worker_connections` | `keepalive_timeout` | `memory_limit` | OPcache (MB) | `pm.max_children` | Reserved for OS/DB (MB) |
|-----|----------------------|---------------------|----------------|--------------|-------------------|-------------------------|
| 2 GB | 2048 | 15 | 256M | 128 | 10 | 700 |
| 4 GB | 4096 | 20 | 384M | 192 | 20 | 1200 |
| 8 GB | 8192 | 30 | 512M | 256 | 40 | 2000 |
| 16 GB | 16384 | 45 | 512M | 384 | 80 | 3500 |
| 32 GB | 32768 | 60 | 512M | 512 | 160 | 6000 |

The 4 GB reserve assumes MySQL or PostgreSQL shares the box. If the database runs elsewhere, raise the worker count with `--php-max-children`.
