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
   - Generates the application key and Passport keys.
   - Prepares a SQLite database and runs `php artisan icons:cache && php artisan test --parallel`.
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

## Adding the workflow to your repo
1. Copy `.github/workflows/laravel-ci-cd-template.yml` into your project.
2. Replace placeholders (branch names, paths, PHP version) with your project’s values.
3. Commit the workflow and push to GitHub. The pipeline will run on the next push to the configured branch and deploy automatically after tests succeed.
