# Laravel Deployment Automation Script

This repository contains a bash script to automate the deployment of a Laravel application with Nginx, PHP 8.2, MySQL, Memcached, and SSL on an Ubuntu server.

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
- Optionally pushes local changes back to the GitHub repository.

## How to Use

### Step 1: Clone the Repository

SSH into your Ubuntu server and clone this repository:

```bash
git clone https://github.com/theafolayan/setup.git
```
