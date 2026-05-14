# Mike

Mike is a legal document assistant with a Next.js frontend, an Express backend, Supabase Auth/Postgres, and Cloudflare R2-compatible object storage.

Website: [mikeoss.com](https://mikeoss.com)

## Contents

- `frontend/` - Next.js application
- `backend/` - Express API, Supabase access, document processing, and database schema
- `backend/schema.sql` - Supabase schema for fresh databases
- `backend/migrations/` - incremental database updates for existing deployments

## Prerequisites

- Node.js 20 or newer
- npm
- git
- A Supabase project
- A Cloudflare R2 bucket, MinIO bucket, or another S3-compatible bucket
- At least one supported model provider API key: Anthropic, Google Gemini, or OpenAI
- LibreOffice installed locally if you need DOC/DOCX to PDF conversion

## Database Setup

For a new Supabase database, open the Supabase SQL editor and run:

```sql
-- copy and run the contents of:
-- backend/schema.sql
```

The schema file is based on `supabase-migration.sql` and folds in the later files in `backend/migrations/`.

For an existing database, do not run the full schema file over production data. Apply the incremental files in `backend/migrations/` instead.

## Environment

Create local env files:

```bash
touch backend/.env
touch frontend/.env.local
```

Create `backend/.env`:

```bash
PORT=3001
FRONTEND_URL=http://localhost:3000
DOWNLOAD_SIGNING_SECRET=replace-with-a-random-32-byte-hex-string
SUPABASE_URL=https://your-project.supabase.co
SUPABASE_SECRET_KEY=your-supabase-service-role-key

R2_ENDPOINT_URL=https://your-account-id.r2.cloudflarestorage.com
R2_ACCESS_KEY_ID=your-r2-access-key
R2_SECRET_ACCESS_KEY=your-r2-secret-key
R2_BUCKET_NAME=mike

GEMINI_API_KEY=your-gemini-key
ANTHROPIC_API_KEY=your-anthropic-key
OPENAI_API_KEY=your-openai-key
RESEND_API_KEY=your-resend-key
USER_API_KEYS_ENCRYPTION_SECRET=your-long-random-secret
```

Create `frontend/.env.local`:

```bash
NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co
NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY=your-supabase-anon-key
SUPABASE_SECRET_KEY=your-supabase-service-role-key
NEXT_PUBLIC_API_BASE_URL=http://localhost:3001
```

Supabase values come from the project dashboard. Use the project URL for `SUPABASE_URL` / `NEXT_PUBLIC_SUPABASE_URL`, the service role key for `SUPABASE_SECRET_KEY`, and the anon/public key for `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY`. If your Supabase project shows multiple key formats, use the legacy JWT-style anon and service role keys expected by the Supabase client libraries.

Provider keys are only needed for the models and email features you plan to use. Model provider keys can be configured in `backend/.env` for the whole instance, or per user in **Account > Models & API Keys**. If a provider key is present in `backend/.env`, that provider is available by default and the matching browser API key field is read-only.

## Install

Install each app package:

```bash
npm install --prefix backend
npm install --prefix frontend
```

## Run Locally

Start the backend:

```bash
npm run dev --prefix backend
```

Start the main app:

```bash
npm run dev --prefix frontend
```

Open `http://localhost:3000`.

## First Run

1. Sign up in the app.
2. If you did not set provider keys in `backend/.env`, open **Account > Models & API Keys** and add an Anthropic, Gemini, or OpenAI API key.
3. Create or open a project and start chatting with documents.

## Troubleshooting

**Sign-up confirmation email never arrives.** Confirmation emails are sent by Supabase Auth, not by Mike. For local development, the simplest fix is to disable email confirmation in **Supabase > Authentication > Providers > Email**. For production, configure custom SMTP in Supabase; the built-in mailer is heavily rate-limited and may be restricted on newer projects.

**The model picker shows a missing-key warning.** Add a key for that provider in **Account > Models & API Keys**, or configure the provider key in `backend/.env` and restart the backend.

**DOC or DOCX conversion fails.** Install LibreOffice locally and restart the backend so document conversion commands are available on the process path.

## Useful Checks

```bash
npm run build --prefix backend
npm run build --prefix frontend
npm run lint --prefix frontend
```

## Deploy On Fly.io

The devcontainer includes `flyctl`, and the recommended path is the interactive deploy script at `scripts/deploy-fly.sh`.

### 1. Rebuild The Devcontainer And Authenticate

Rebuild/reopen the devcontainer after pulling the latest changes, then authenticate inside the container:

```bash
flyctl auth login
```

### 2. Run The Deploy Script

From the repo root:

```bash
./scripts/deploy-fly.sh
```

The script will:

- prompt for an app prefix and create `${prefix}-mike-api` / `${prefix}-mike-web` or unprefixed `mike-api` / `mike-web`
- read shared values from `backend/.env`, `frontend/.env.local`, and the current shell environment
- derive the Fly URLs automatically instead of reusing your local `localhost` values
- generate `DOWNLOAD_SIGNING_SECRET` and `USER_API_KEYS_ENCRYPTION_SECRET` when they are missing
- prompt for any required values that are still missing
- optionally write non-derived values back into your ignored local env files so future deploys reuse the same secrets
- create the Fly apps if they do not exist yet
- retry transient Fly remote-builder failures automatically, first with `--recreate-builder` and then with Depot if needed
- stage secrets once and then deploy backend first, frontend second

The script uses temporary Fly config files, so you do not need to edit `backend/fly.toml` or `frontend/fly.toml` when your app names or region change.

If deploys still fail at `Waiting for depot builder...`, `error reporting health`, or `connection reset by peer` even after the script retries, treat that as a Fly builder-region outage. The next fix is usually in the Fly dashboard under `Org > Settings > App Builders > Configure`: move the builder region away from `YYZ` to a different region such as `ORD` or `IAD`, then rerun the script.

### 3. Optional Flags

```bash
./scripts/deploy-fly.sh --prefix juleskuehn
./scripts/deploy-fly.sh --prefix juleskuehn --region yyz
./scripts/deploy-fly.sh --prefix juleskuehn --org personal --dry-run
./scripts/deploy-fly.sh --prefix juleskuehn --build-strategy depot
./scripts/deploy-fly.sh --prefix juleskuehn --build-strategy remote
./scripts/deploy-fly.sh --yes --prefix juleskuehn --no-write-env-files
```

### 4. Verify

Check both health endpoints after deploy:

```bash
curl https://your-prefix-mike-api.fly.dev/health
curl https://your-prefix-mike-web.fly.dev/api/health
```

If you deploy without a prefix, those URLs become `https://mike-api.fly.dev/health` and `https://mike-web.fly.dev/api/health`.

### 5. Manual Fallback

If you skip the script, pass explicit `--app` values to `flyctl secrets set` and `flyctl deploy`, or update the `app =` value in `backend/fly.toml` and `frontend/fly.toml` yourself.

### 6. GitHub Actions Fallback

If Fly deploys from the devcontainer still fail with `Waiting for depot builder...`, `connection reset by peer`, WireGuard gateway failures, or TLS interception on `*.gateway.6pn.dev`, use the GitHub Actions workflow in `.github/workflows/deploy-fly.yml` instead. It runs on `ubuntu-latest`, where Docker is available, and calls the same deploy script with `--build-strategy local` so it does not depend on Fly's remote/depot builders.

After rebuilding the devcontainer so `gh` is available, avoid browser auth on this network. Use either a GitHub personal access token in the terminal or `gh auth login --with-token`.

Preferred terminal-only path:

```bash
export GH_TOKEN=your-github-token
```

Alternative if you want `gh` to store the token locally:

```bash
gh auth login --with-token
```

Then sync your local deployment values into GitHub repository secrets:

```bash
./scripts/sync-github-secrets.sh
```

The helper reads `backend/.env`, `frontend/.env.local`, the current shell environment, and `flyctl auth token`, generates `DOWNLOAD_SIGNING_SECRET` and `USER_API_KEYS_ENCRYPTION_SECRET` if missing, and uploads the result with `gh secret set`. It accepts `GH_TOKEN` / `GITHUB_TOKEN`, stored `gh` auth, or a direct hidden prompt in the terminal.

Optional flags:

```bash
./scripts/sync-github-secrets.sh --dry-run
./scripts/sync-github-secrets.sh --repo owner/repo
./scripts/sync-github-secrets.sh --yes --no-write-env-files
```

The workflow expects these repository secrets:

- `FLY_API_TOKEN`
- `SUPABASE_URL`
- `NEXT_PUBLIC_SUPABASE_URL`
- `SUPABASE_SECRET_KEY`
- `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY`
- `R2_ENDPOINT_URL`
- `R2_ACCESS_KEY_ID`
- `R2_SECRET_ACCESS_KEY`
- `R2_BUCKET_NAME`
- `DOWNLOAD_SIGNING_SECRET`
- `USER_API_KEYS_ENCRYPTION_SECRET`

Optional repository secrets:

- `GEMINI_API_KEY`
- `ANTHROPIC_API_KEY`
- `OPENAI_API_KEY`
- `RESEND_API_KEY`

Then run the workflow manually from the GitHub Actions tab and provide the same prefix and region you would pass locally.

### Notes

- The backend image installs LibreOffice because document conversion depends on it.
- The frontend uses Next.js standalone output and includes `sharp` for production image optimization.
- The devcontainer includes LibreOffice, `flyctl`, and `gh`, so local conversion, GitHub secret sync, and Fly deployment tooling live in the same environment.
- Some VPN or corporate-network environments block UDP WireGuard and MITM-intercept Fly gateway HTTPS. In that case, deploying from this devcontainer can fail even when app config is correct; the GitHub Actions workflow is the reliable fallback.
- If you attach custom domains, update `FRONTEND_URL`, `NEXT_PUBLIC_SITE_URL`, and `NEXT_PUBLIC_API_BASE_URL` to match those domains.
