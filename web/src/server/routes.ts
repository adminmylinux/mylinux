import { displayName, hashToken, identify, TOKEN_PREFIX, unauthenticated, type Identity } from "./auth";
import { sql } from "./db";
import { fromIni, normalizeConfig, toIni, type MachineConfig } from "./ini";

type Machine = { id: string; name: string; config: MachineConfig; created_at: string; updated_at: string };

const json = (data: unknown, status = 200) => Response.json(data, { status });
const bad = (message: string, status = 400) => json({ error: message }, status);

const NAME_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/i;
const validName = (n: unknown): n is string => typeof n === "string" && NAME_RE.test(n);

/** Wrap a handler so it only runs for an identified user. */
const withUser =
  <T extends Record<string, string>>(fn: (req: Request, me: Identity, params: T) => Promise<Response>) =>
  async (req: Request & { params: T }) => {
    const me = await identify(req);
    if (!me) return unauthenticated();
    return fn(req, me, req.params);
  };

const listMachines = (userId: string) =>
  sql<Machine[]>`
    SELECT id, name, config, created_at, updated_at FROM machines
    WHERE user_id = ${userId} ORDER BY name`;

const findMachine = async (userId: string, idOrName: string) => {
  const byId = /^[0-9a-f-]{36}$/i.test(idOrName);
  const rows = byId
    ? await sql<Machine[]>`SELECT id, name, config, created_at, updated_at FROM machines WHERE user_id = ${userId} AND id = ${idOrName}`
    : await sql<Machine[]>`SELECT id, name, config, created_at, updated_at FROM machines WHERE user_id = ${userId} AND name = ${idOrName}`;
  return rows[0] ?? null;
};

async function saveMachine(userId: string, name: string, config: MachineConfig): Promise<Machine> {
  const rows = await sql<Machine[]>`
    INSERT INTO machines (user_id, name, config) VALUES (${userId}, ${name}, ${config}::jsonb)
    ON CONFLICT (user_id, name) DO UPDATE SET config = EXCLUDED.config, updated_at = now()
    RETURNING id, name, config, created_at, updated_at`;
  return rows[0];
}

export const routes = {
  "/api/health": () => json({ ok: true }),

  "/api/me": withUser(async (_req, me) => json({ userId: me.userId, name: await displayName(me.userId), via: me.via })),

  "/api/machines": {
    GET: withUser(async (_req, me) => json(await listMachines(me.userId))),
    POST: withUser(async (req, me) => {
      const body = await req.json().catch(() => null);
      if (!validName(body?.name)) return bad("name: letters, digits, dot, dash or underscore, up to 64 characters");
      if (await findMachine(me.userId, body.name)) return bad("a machine with that name already exists", 409);
      const count = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM machines WHERE user_id = ${me.userId}`;
      if (count[0].n >= 50) return bad("at most 50 machines per account", 409);
      return json(await saveMachine(me.userId, body.name, normalizeConfig(body.config)), 201);
    }),
  },

  "/api/machines/:id": {
    GET: withUser<{ id: string }>(async (_req, me, { id }) => {
      const m = await findMachine(me.userId, id);
      return m ? json(m) : bad("not found", 404);
    }),
    PUT: withUser<{ id: string }>(async (req, me, { id }) => {
      const m = await findMachine(me.userId, id);
      if (!m) return bad("not found", 404);
      const body = await req.json().catch(() => null);
      const name = body?.name ?? m.name;
      if (!validName(name)) return bad("invalid name");
      if (name !== m.name && (await findMachine(me.userId, name))) return bad("a machine with that name already exists", 409);
      const config = normalizeConfig(body?.config ?? m.config);
      const rows = await sql<Machine[]>`
        UPDATE machines SET name = ${name}, config = ${config}::jsonb, updated_at = now()
        WHERE id = ${m.id} RETURNING id, name, config, created_at, updated_at`;
      return json(rows[0]);
    }),
    DELETE: withUser<{ id: string }>(async (_req, me, { id }) => {
      const m = await findMachine(me.userId, id);
      if (!m) return bad("not found", 404);
      await sql`DELETE FROM machines WHERE id = ${m.id}`;
      return json({ ok: true });
    }),
  },

  /** The ini form of a machine, for scripts inside myLinux:
   *    curl -H "Authorization: Bearer mlx_..." https://mylinux.app/api/machines/<name>/ini > share/mylinux.ini
   *    curl -X PUT --data-binary @share/mylinux.ini -H "Authorization: Bearer mlx_..." https://mylinux.app/api/machines/<name>/ini
   * PUT creates the machine when it does not exist yet. */
  "/api/machines/:id/ini": {
    GET: withUser<{ id: string }>(async (_req, me, { id }) => {
      const m = await findMachine(me.userId, id);
      if (!m) return bad("not found", 404);
      return new Response(toIni(m.config), { headers: { "content-type": "text/plain; charset=utf-8" } });
    }),
    PUT: withUser<{ id: string }>(async (req, me, { id }) => {
      const text = await req.text();
      if (text.length > 64 * 1024) return bad("ini too large");
      const m = await findMachine(me.userId, id);
      if (!m && !validName(id)) return bad("invalid machine name");
      const config = fromIni(text, m?.config);
      const saved = await saveMachine(me.userId, m?.name ?? id, config);
      return json({ ok: true, id: saved.id, name: saved.name, updated_at: saved.updated_at });
    }),
  },

  "/api/tokens": {
    GET: withUser(async (_req, me) =>
      json(
        await sql`SELECT id, name, prefix, created_at, last_used_at FROM api_tokens
                  WHERE user_id = ${me.userId} ORDER BY created_at DESC`,
      ),
    ),
    POST: withUser(async (req, me) => {
      if (me.via !== "session") return bad("tokens can only be created from the website", 403);
      const body = await req.json().catch(() => null);
      const name = typeof body?.name === "string" && body.name.trim() ? body.name.trim().slice(0, 64) : "token";
      const count = await sql<{ n: number }[]>`SELECT count(*)::int AS n FROM api_tokens WHERE user_id = ${me.userId}`;
      if (count[0].n >= 20) return bad("at most 20 tokens per account", 409);
      const secret = TOKEN_PREFIX + Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64url");
      const prefix = secret.slice(0, 10);
      const rows = await sql<{ id: string; created_at: string }[]>`
        INSERT INTO api_tokens (user_id, name, prefix, token_hash)
        VALUES (${me.userId}, ${name}, ${prefix}, ${await hashToken(secret)})
        RETURNING id, created_at`;
      // the secret is shown once; only its hash is stored
      return json({ id: rows[0].id, name, prefix, created_at: rows[0].created_at, token: secret }, 201);
    }),
  },

  "/api/tokens/:id": {
    DELETE: withUser<{ id: string }>(async (_req, me, { id }) => {
      if (me.via !== "session") return bad("tokens can only be revoked from the website", 403);
      await sql`DELETE FROM api_tokens WHERE user_id = ${me.userId} AND id = ${id}`;
      return json({ ok: true });
    }),
  },

  "/api/*": () => bad("not found", 404),
};
