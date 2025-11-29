# GitHub Actions CI/CD for Laravel

This guide outlines how to automate testing and deployments whenever code is pushed to a chosen branch. Use the accompanying workflow template at `.github/workflows/laravel-ci-cd-template.yml` and adjust environment details to fit your servers and branching strategy.

## Prerequisites
- A branch dedicated to deployment (for example `main`, `master`, or `staging`).
- An SSH-accessible host with your Laravel project checked out and ready to receive `git pull` updates.
- GitHub repository secrets configured for SSH access:
  - `SSH_HOST`: The server hostname or IP address.
  - `SSH_PORT`: The SSH port (default `22`).
  - `SSH_USERNAME`: SSH user with deploy permissions.
  - `SSH_KEY`: Private key with access to the host (use the **long** multi-line value).
- Optional: Adjust the `~/www/staging` paths in the template to match your server layout.

## How the template works
1. **Trigger**: Fires on pushes to the configured branch (default: `main`).
2. **Test job**:
   - Sets up PHP 8.2 with required extensions.
   - Checks out the repository.
   - Copies `.env` and `.env.testing` from the example files when they are missing.
   - Installs Composer dependencies without dev scripts.
   - Generates the application key and runs `passport:keys` only when the command exists.
   - Prepares a SQLite database, warms the Blade Icons cache when available, and runs `php artisan test --parallel`.
3. **Deploy job** (runs only if tests pass):
   - Reuses the branch condition (`refs/heads/main`) to guard deployments.
   - Connects via SSH and performs:
     - `artisan down` to enter maintenance mode.
     - `git pull` followed by Composer install and autoload optimization.
     - `php artisan migrate --force` and cache clearing.
     - Supervisor restart for queue workers.
     - `artisan up` to bring the app back online.

## Customizing the workflow
- **Branch**: Update `on.push.branches` and the `if: github.ref` check to match your deploy branch.
- **PHP version**: Adjust `php-version` and extensions if your app targets a different PHP release.
- **Environment files**: Ensure `.env.example` and `.env.testing.example` contain the right defaults for CI.
- **Database**: Replace the SQLite setup with your preferred database service (MySQL/PostgreSQL) if needed.
- **Deployment script**: Edit the SSH script to point to your project path, queue manager, and any extra build steps (e.g., `npm ci && npm run build`).
- **Secrets**: If you use additional secrets (e.g., `DEPLOY_PATH`, `SUPERVISOR_NAME`), add them under the `with:` block of the deploy step.

## Deploying to AWS Lightsail
You can reuse the template to deploy to an AWS Lightsail instance because Lightsail exposes standard SSH access.

1. **Set up the Lightsail server**
   - Create a Linux/Unix instance and attach a static IP.
   - Open ports for HTTP/HTTPS (80/443) and SSH (22 by default) in the networking tab.
   - Install system dependencies on the instance: PHP extensions required by your app, Composer, Git, Nginx/Apache, Supervisor, and Node tooling if you build frontend assets.
   - Create a non-root deploy user (for example `deploy`) with sudo access for service restarts.

2. **Provision the application**
   - Clone your repository to a path such as `/home/deploy/www/staging` and configure the virtual host to serve from `public/`.
   - Create `.env` with production/staging values and ensure `storage/` and `bootstrap/cache/` are writable by the web server and deploy user.
   - Set up Supervisor (or systemd) to run queues/schedulers if needed and note the service name you want to restart after deploys.

3. **Configure GitHub secrets**
   - `SSH_HOST`: Lightsail public IP or DNS.
   - `SSH_PORT`: Usually `22` unless you customized it.
   - `SSH_USERNAME`: The deploy user (e.g., `deploy`).
   - `SSH_KEY`: The private key that matches the deploy user’s authorized key on Lightsail.
   - Optional: `DEPLOY_PATH` (e.g., `/home/deploy/www/staging`) and `SUPERVISOR_PROGRAM` (e.g., `all` or a queue name) to avoid hardcoding paths in the workflow.

4. **Adjust the workflow deploy step**
   - Replace the `cd ~/www/staging` path with your Lightsail path (or reference `${{ secrets.DEPLOY_PATH }}` if you add it).
   - Swap `sudo supervisorctl restart all` with the service restart you use on Lightsail (for example `sudo systemctl restart php8.2-fpm` or `sudo supervisorctl restart ${SUPERVISOR_PROGRAM:-all}`).
   - Keep `artisan down/up`, `git pull`, `composer install`, and `php artisan migrate --force` unless your rollout process differs.

5. **Test the pipeline**
   - Push a test commit to the configured branch. Verify the workflow output shows the SSH deploy step running and check your Lightsail instance to confirm the code and caches updated.

With these adjustments, the same CI/CD template can deploy reliably to AWS Lightsail using your existing SSH-based process.

## Adding the workflow to your repo
1. Copy `.github/workflows/laravel-ci-cd-template.yml` into your project.
2. Replace placeholders (branch names, paths, PHP version) with your project’s values.
3. Commit the workflow and push to GitHub. The pipeline will run on the next push to the configured branch and deploy automatically after tests succeed.
