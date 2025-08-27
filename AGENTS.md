# AGENTS: Contribution Guidelines for Opinionpadi

## Overview
Opinionpadi is a user research platform that does three things:
1. Lets businesses create paid surveys and have people fill them in exchange for rewards.
2. Lets businesses run product feedback runs where vetted testers give honest feedback on digital products.
3. Lets businesses run UGC campaigns where vetted users with creator profiles produce content for the business and share it on their socials.

These guidelines apply to the entire repository.

## Code Style
### PHP
- Follow [PSR-12](https://www.php-fig.org/psr/psr-12/) coding standards.
- Prefer explicit types, strict comparisons, and early returns.
- Name classes using `StudlyCase` and methods using `camelCase`.
- Place controllers in `app/Http/Controllers` and services in `app/Services`.

### Shell Scripts
- Begin scripts with `#!/usr/bin/env bash` and `set -euo pipefail`.
- Keep functions short and use descriptive names.
- Validate scripts with `shellcheck`.

### JavaScript / TypeScript
- Use ESLint with the Airbnb config and Prettier for formatting.
- Keep components small and composable.

## Testing Strategy
- Every new feature must include unit or feature tests.
- Run the full test suite with `composer test` (alias for `php artisan test`).
- Run `shellcheck` on any modified shell scripts.
- Ensure all tests pass before committing and opening a pull request.

## API Documentation Style
- Document endpoints in `docs/api` using the OpenAPI 3.1 specification (`.yaml` files).
- Pair each endpoint with a Markdown file that includes a clear description and request/response examples. For example:

```
## Change Password
**POST** `/password` *(requires authentication)*

Change the account password using the current password for verification.

### Request
```json
{
  "current_password": "oldpass",
  "password": "newsecret",
  "password_confirmation": "newsecret"
}
```

### Response `200`
```json
{
  "message": "Password updated"
}
```
```
- Use RESTful naming conventions (`/surveys`, `/product-runs`, `/ugc-campaigns`).
- Keep documentation synchronized with the implemented endpoints.

## Commit Messages
- Use the imperative mood ("Add survey model" not "Added" or "Adds").
- Reference relevant issues or tickets when available.

## Pull Requests
- Include a summary of changes and testing evidence.
- If the change affects APIs, update the OpenAPI docs in `docs/api`.

## Security and Configuration
- Never commit secrets; use environment variables and keep `.env` files out of version control.
- Provide updates to `.env.example` when configuration variables change.

## Documentation
- Use Markdown for user-facing docs. Place user documentation in `docs/users` and business-facing documentation in `docs/businesses`. Keep titles concise.
- For architectural decisions, add entries in `docs/adr/` following the [ADR](https://adr.github.io/) format.

## Dependencies and Tooling
- Use Composer for PHP dependencies and `npm` or `yarn` for frontend assets.
- Lock files (`composer.lock`, `package-lock.json` or `yarn.lock`) must be committed.

By following these guidelines, contributors help maintain a consistent and high-quality codebase for Opinionpadi.
