# Laravel Deployment Automation Script

This repository contains a bash script to automate the deployment of a Laravel application with Nginx, PHP 8.2, MySQL, Memcached, and SSL on an Ubuntu (Or Similar arch) server.

## Prerequisites

Before running this script, ensure that:
- You have root (sudo) access to the Ubuntu server.
- The server is accessible and has an open port for SSH connections.
- You have a domain name configured to point to your server.

## Features

- Installs Nginx, PHP 8.2, MySQL, Memcached, and Composer.
- Clones a Laravel project from a specified GitHub repository.
- Automatically configures Nginx to serve the Laravel app using your provided domain.
- Configures SSL using Let's Encrypt with Certbot.
- Optionally pushes local changes back to the GitHub repository. (Coming Soon)

## How to Use

### Step 1: Clone the Repository

SSH into your Ubuntu server and clone this repository:

```bash
wget https://raw.githubusercontent.com/theafolayan/setup-laravel/main/setup_laravel_nginx_ssl.sh
```

## Step 2: Make the Script Executable
Make the script executable:


```bash 
chmod +x setup_laravel_nginx_ssl.sh
```
## Step 3: Run the Script
Run the script with superuser privileges to start the installation process:

```bash
sudo ./setup_laravel_nginx_ssl.sh
```
The script will prompt you for the following information:

- Domain name: Provide the domain name you want to use for your Laravel app (e.g., example.com).
- GitHub repository URL: Provide the URL of the Laravel project repository (e.g., https://github.com/username/laravel-app.git).

## Step 4: SSL Setup
The script will automatically configure SSL using Let's Encrypt for the provided domain.

Ensure that your domain DNS is correctly set up to point to the server's IP address. Certbot will handle the SSL setup and configure Nginx to use the certificates.