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

This repo deploys cleanly to Fly.io as two apps:

- `mike-api` for the Express backend
- `mike-web` for the Next.js frontend

The backend and frontend now each include a `fly.toml`, Dockerfile, and `.dockerignore`.

### 1. Rebuild The Devcontainer And Authenticate

The devcontainer installs `flyctl`. Rebuild/reopen the devcontainer after pulling the latest changes, then authenticate inside the container:

```bash
fly auth login
```

### 2. Create The Apps

Create one Fly app for each service from inside the devcontainer. Replace the names if you want different app names:

```bash
fly apps create mike-api
fly apps create mike-web
```

If you want a specific region, set it during launch or update `primary_region` in each `fly.toml`.

### 3. Set Backend Secrets

Set the backend secrets from the `backend/` directory inside the devcontainer:

```bash
cd backend
fly secrets set \
	FRONTEND_URL=https://mike-web.fly.dev \
	DOWNLOAD_SIGNING_SECRET=replace-with-a-random-32-byte-hex-string \
	SUPABASE_URL=https://your-project.supabase.co \
	SUPABASE_SECRET_KEY=your-supabase-service-role-key \
	R2_ENDPOINT_URL=https://your-account-id.r2.cloudflarestorage.com \
	R2_ACCESS_KEY_ID=your-r2-access-key \
	R2_SECRET_ACCESS_KEY=your-r2-secret-key \
	R2_BUCKET_NAME=mike \
	USER_API_KEYS_ENCRYPTION_SECRET=your-long-random-secret \
	GEMINI_API_KEY=your-gemini-key \
	ANTHROPIC_API_KEY=your-anthropic-key \
	OPENAI_API_KEY=your-openai-key \
	RESEND_API_KEY=your-resend-key \
	--app mike-api
```

Only set provider keys you actually want globally enabled.

### 4. Set Frontend Secrets

Set the frontend runtime variables from the `frontend/` directory inside the devcontainer:

```bash
cd ../frontend
fly secrets set \
	NEXT_PUBLIC_SITE_URL=https://mike-web.fly.dev \
	NEXT_PUBLIC_API_BASE_URL=https://mike-api.fly.dev \
	NEXT_PUBLIC_SUPABASE_URL=https://your-project.supabase.co \
	NEXT_PUBLIC_SUPABASE_PUBLISHABLE_DEFAULT_KEY=your-supabase-anon-key \
	SUPABASE_SECRET_KEY=your-supabase-service-role-key \
	R2_ENDPOINT_URL=https://your-account-id.r2.cloudflarestorage.com \
	R2_ACCESS_KEY_ID=your-r2-access-key \
	R2_SECRET_ACCESS_KEY=your-r2-secret-key \
	R2_BUCKET_NAME=mike \
	--app mike-web
```

### 5. Deploy

Deploy the backend first, then the frontend, from inside the devcontainer:

```bash
cd /path/to/repo/backend
fly deploy --remote-only

cd /path/to/repo/frontend
fly deploy --remote-only
```

### 6. Verify

Check both health endpoints after deploy:

```bash
curl https://mike-api.fly.dev/health
curl https://mike-web.fly.dev/api/health
```

### Notes

- The backend image installs LibreOffice because document conversion depends on it.
- The frontend uses Next.js standalone output and includes `sharp` for production image optimization.
- The devcontainer includes both LibreOffice and `flyctl`, so local conversion and Fly deployment work from the same environment.
- If you attach custom domains, update `FRONTEND_URL`, `NEXT_PUBLIC_SITE_URL`, and `NEXT_PUBLIC_API_BASE_URL` to match those domains.
