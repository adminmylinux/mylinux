import { displayName, hashToken, identify, TOKEN_PREFIX, unauthenticated, type Identity } from "./auth";
import { ConfigError, fromIni, normalizeConfig, toIni } from "./ini";
import { ConflictError, LimitError, pgStore, type Store } from "./store";

const json = (data: unknown, status = 200) => Response.json(data, { status });
const bad = (message: string, status = 400, extra: Record<string, unknown> = {}) => json({ error: message, ...extra }, status);

const NAME_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/i;
const validName = (n: unknown): n is string => typeof n === "string" && NAME_RE.test(n);
const MAX_JSON_BYTES = 256 * 1024;
const MAX_INI_BYTES = 64 * 1024;

/** Read a body of bounded size: refuse by Content-Length first, then while streaming. */
async function readBounded(req: Request, max: number): Promise<string | null> {
  const declared = Number(req.headers.get("content-length") ?? "0");
  if (declared > max) return null;
  if (!req.body) return "";
  const reader = req.body.getReader();
  const chunks: Uint8Array[] = [];
  let size = 0;
  for (;;) {
    const { done, value } = await reader.read();
    if (done) break;
    size += value.byteLength;
    if (size > max) { await reader.cancel(); return null; }
    chunks.push(value);
  }
  return new TextDecoder().decode(Buffer.concat(chunks));
}
async function readJson(req: Request): Promise<{ body: unknown } | { error: Response }> {
  const text = await readBounded(req, MAX_JSON_BYTES);
  if (text === null) return { error: bad("request body too large", 413) };
  if (!text.trim()) return { body: {} };
  try { return { body: JSON.parse(text) }; } catch { return { error: bad("malformed JSON") }; }
}
const isRecord = (v: unknown): v is Record<string, unknown> => !!v && typeof v === "object" && !Array.isArray(v);

/** Map thrown domain errors to 4xx responses. */
async function guarded(fn: () => Promise<Response>): Promise<Response> {
  try { return await fn(); }
  catch (e) {
    if (e instanceof ConfigError) return bad("invalid configuration", 422, { problems: e.problems });
    if (e instanceof ConflictError) return bad(e.message, 409);
    if (e instanceof LimitError) return bad(e.message, 409);
    throw e;
  }
}

export function makeRoutes(store: Store) {
  /** Wrap a handler so it only runs for an identified user. */
  const withUser =
    <T extends Record<string, string>>(fn: (req: Request, me: Identity, params: T) => Promise<Response>) =>
    async (req: Request & { params: T }) => {
      const me = await identify(req);
      if (!me) return unauthenticated();
      return guarded(() => fn(req, me, req.params));
    };

  return {
    "/api/health": () => json({ ok: true }),

    "/api/me": withUser(async (_req, me) => json({ userId: me.userId, name: await displayName(me.userId), via: me.via })),

    "/api/machines": {
      GET: withUser(async (_req, me) => json(await store.listMachines(me.userId))),
      POST: withUser(async (req, me) => {
        const r = await readJson(req);
        if ("error" in r) return r.error;
        const body = isRecord(r.body) ? r.body : {};
        if (!validName(body.name)) return bad("name: letters, digits, dot, dash or underscore, up to 64 characters");
        const config = normalizeConfig(body.config ?? {});
        return json(await store.createMachine(me.userId, body.name, config), 201);
      }),
    },

    "/api/machines/:id": {
      GET: withUser<{ id: string }>(async (_req, me, { id }) => {
        const m = await store.findMachine(me.userId, id);
        return m ? json(m) : bad("not found", 404);
      }),
      PUT: withUser<{ id: string }>(async (req, me, { id }) => {
        const m = await store.findMachine(me.userId, id);
        if (!m) return bad("not found", 404);
        const r = await readJson(req);
        if ("error" in r) return r.error;
        const body = isRecord(r.body) ? r.body : {};
        const name = body.name ?? m.name;
        if (!validName(name)) return bad("invalid name");
        if (name !== m.name && (await store.findMachine(me.userId, name))) return bad("a machine with that name already exists", 409);
        const config = normalizeConfig(body.config ?? m.config);
        const saved = await store.updateMachine(me.userId, m.id, name, config);
        return saved ? json(saved) : bad("not found", 404);
      }),
      DELETE: withUser<{ id: string }>(async (_req, me, { id }) => {
        const m = await store.findMachine(me.userId, id);
        if (!m) return bad("not found", 404);
        await store.deleteMachine(me.userId, m.id);
        return json({ ok: true });
      }),
    },

    /** The ini form of a machine, for scripts inside myLinux:
     *    curl -H "Authorization: Bearer mlx_..." https://mylinux.app/api/machines/<name>/ini > share/mylinux.ini
     *    curl -X PUT --data-binary @share/mylinux.ini -H "Authorization: Bearer mlx_..." https://mylinux.app/api/machines/<name>/ini
     * PUT creates the machine when it does not exist yet (an upsert, on purpose). Bad values in the
     * ini fall back to the stored ones and are listed in "problems". */
    "/api/machines/:id/ini": {
      GET: withUser<{ id: string }>(async (_req, me, { id }) => {
        const m = await store.findMachine(me.userId, id);
        if (!m) return bad("not found", 404);
        return new Response(toIni(m.config), { headers: { "content-type": "text/plain; charset=utf-8" } });
      }),
      PUT: withUser<{ id: string }>(async (req, me, { id }) => {
        const text = await readBounded(req, MAX_INI_BYTES);
        if (text === null) return bad("ini too large", 413);
        const m = await store.findMachine(me.userId, id);
        if (!m && !validName(id)) return bad("invalid machine name");
        const { config, problems } = fromIni(text, m?.config);
        const saved = await store.upsertMachine(me.userId, m?.name ?? id, config);
        return json({ ok: true, id: saved.id, name: saved.name, updated_at: saved.updated_at, problems });
      }),
    },

    "/api/tokens": {
      GET: withUser(async (_req, me) => json(await store.listTokens(me.userId))),
      POST: withUser(async (req, me) => {
        if (me.via !== "session") return bad("tokens can only be created from the website", 403);
        const r = await readJson(req);
        if ("error" in r) return r.error;
        const body = isRecord(r.body) ? r.body : {};
        const name = typeof body.name === "string" && body.name.trim() ? body.name.trim().slice(0, 64) : "token";
        const secret = TOKEN_PREFIX + Buffer.from(crypto.getRandomValues(new Uint8Array(24))).toString("base64url");
        const prefix = secret.slice(0, 10);
        const row = await store.createToken(me.userId, name, prefix, await hashToken(secret));
        // the secret is shown once; only its hash is stored
        return json({ id: row.id, name, prefix, created_at: row.created_at, token: secret }, 201);
      }),
    },

    "/api/tokens/:id": {
      DELETE: withUser<{ id: string }>(async (_req, me, { id }) => {
        if (me.via !== "session") return bad("tokens can only be revoked from the website", 403);
        await store.deleteToken(me.userId, id);
        return json({ ok: true });
      }),
    },

    "/api/*": () => bad("not found", 404),
  };
}

export const routes = makeRoutes(pgStore);
