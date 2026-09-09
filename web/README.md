# mylinux.app

The website for myLinux: landing page, docs, and an account that keeps one
profile per machine (the contents of `share/mylinux.ini` plus a package list
and notes) so a setup can be carried between Macs.

- Bun serves the API and three bundled pages: `/` (landing), `/docs`, and the
  React account app at `/app`, `/sign-in`, `/sign-up`.
- Accounts: [Clerk](https://clerk.com). Without `CLERK_*` keys the public pages
  work and `/app` explains that sign-in is not configured.
- Data: Postgres, tables created at startup (`src/server/db.ts`).
- API tokens (`mlx_…`, SHA-256 hashed at rest) let scripts inside myLinux pull
  and push the ini: see `/docs#api`.

## Develop

```bash
bun install
DATABASE_URL=postgres://postgres:dev@127.0.0.1:55432/mylinux bun run dev   # http://localhost:3000
bun run typecheck
```

## Deploy

Runs on contabogit (84.46.241.200) as `/opt/mylinux-web` with docker compose
(app on 127.0.0.1:8801 + postgres). Caddy on the host terminates TLS for
mylinux.app (`Caddyfile.mylinux` is the site block); Cloudflare DNS has A
records for `mylinux.app` and `www` pointing at the server, unproxied.

```bash
./deploy.sh          # rsync + docker compose up -d --build
```

Secrets live in `/opt/mylinux-web/.env` on the server (template: `.env.example`).
Set `CLERK_PUBLISHABLE_KEY` and `CLERK_SECRET_KEY` there and run
`docker compose up -d` in `/opt/mylinux-web` to switch sign-in on.
