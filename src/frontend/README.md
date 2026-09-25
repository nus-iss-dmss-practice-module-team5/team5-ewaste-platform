# Frontend

Next.js frontend for the e-waste platform. Login uses the workflow API. After login the UI shows **only that user’s role** — the role pill is a label, not a switcher.

From the repo root:

```bash
cd src/frontend
cp .env.example .env.local
npm install
npm test
npm run dev
```

If you are already in this folder, skip `cd`. If you are in WSL and `npm` errors with `\\wsl.localhost\...` or `C:\Users\...`, you are using Windows npm. Check with `which npm`. It should be a Linux path such as `~/.nvm/versions/node/.../bin/npm`. Load nvm (`source ~/.bashrc`), then `rm -rf node_modules` and `npm install` again. Do not use `--legacy-peer-deps` for this.

Open http://localhost:3000 and sign in with a seeded account such as `donor1@ewaste.test`. The accounts and their password are listed in [database/README.md](../../database/README.md#seeded-synthetic-accounts).

`.env.example` points `API_PROXY_TARGET` at the Azure DEV API. To use a local backend instead, set it to `http://localhost:8080` in `.env.local`.

The browser calls `/api/v1/*` on the Next.js origin. Next rewrites that to `API_PROXY_TARGET` so you do not depend on Go CORS. Restart `npm run dev` after changing env. Do not set `API_PROXY_TARGET` to the Azure UI host.

Copy `.env.example` at the repo root for the API base URL. Do not commit `.env` or `.env.local`.

## Redirects and session expiry

- `/` sends signed-out users to `/login` and signed-in users to `/home`.
- `/home` requires a session; otherwise you are sent to `/login` (not treated as expiry).
- `/login` with a session sends you to `/home` (including when you type `/login` in the address bar).
- Access JWT expiry (`expires_in` from the login response) refreshes silently. Refresh JWT expiry or revocation sends you to `/login?expired=1` with **Your session expired. Please sign in again.**
- **Logout** returns to `/login` with no expiry banner.
- **F5 / reload** keeps you on `/home` if the session is still valid. Closing the tab ends the session. This is not `localStorage`; a tab-only copy is used.
