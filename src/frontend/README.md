# Frontend

Next.js login increment for the e-waste platform. Login is **mocked by default**. After login the UI shows **only that user’s role** — the role pill is a label, not a switcher.

From the repo root:

```bash
cd src/frontend
cp .env.example .env.local
npm install
npm test
npm run dev
```

If you are already in this folder, skip `cd`. If you are in WSL and `npm` errors with `\\wsl.localhost\...` or `C:\Users\...`, you are using Windows npm. Check with `which npm`. It should be a Linux path such as `~/.nvm/versions/node/.../bin/npm`. Load nvm (`source ~/.bashrc`), then `rm -rf node_modules` and `npm install` again. Do not use `--legacy-peer-deps` for this.

Open http://localhost:3000. Seeded mock accounts (password `Password1!`):

- `donor@example.com`
- `recycler@example.com`
- `collector@example.com`
- `auditor@example.com`
- `admin@example.com`

To use Jiamin’s workflow API instead, in `.env.local` set:

```bash
NEXT_PUBLIC_USE_MOCK_AUTH=false
API_PROXY_TARGET=http://localhost:8080
```

The browser still calls `/api/v1/auth/login` on the Next.js origin. Next rewrites that to `API_PROXY_TARGET` so you do not depend on Go CORS. Restart `npm run dev` after changing env. Use the seeded users from the workflow API, not the mock emails above.

Copy `.env.example` at the repo root for the API base URL. Do not commit `.env` or `.env.local`.

## Redirects and session expiry

- `/` sends signed-out users to `/login` and signed-in users to `/home`.
- `/home` requires a session; otherwise you are sent to `/login` (not treated as expiry).
- `/login` with a session sends you to `/home` (including when you type `/login` in the address bar).
- Access JWT expiry (15 minutes in the mock) refreshes silently. Refresh JWT expiry or revocation sends you to `/login?expired=1` with **Your session expired. Please sign in again.**
- **Logout** returns to `/login` with no expiry banner.
- **F5 / reload** keeps you on `/home` if the session is still valid. Closing the tab ends the session. This is not `localStorage`; a tab-only copy is used.

When mock auth is on, home has **Simulate access-token expiry** (stay signed in) and **Simulate expired session** (amber banner). Those controls are hidden against the real API.
