/** Route behaviour against an in-memory store that mirrors the Postgres store's transactional
 * guarantees (limits checked with the insert, conflict on create). The real store runs the same
 * scenarios when TEST_DATABASE_URL points at a disposable Postgres. */
import { describe, expect, mock, test } from "bun:test";
import type { MachineConfig } from "./ini";
import { ConflictError, LimitError, MAX_MACHINES, MAX_TOKENS, type Machine, type Store } from "./store";

// identify() is replaced: "Authorization: Bearer test:<user>[:token]" identifies a user
mock.module("./auth", () => ({
  TOKEN_PREFIX: "mlx_",
  hashToken: async (t: string) => "hash:" + t,
  displayName: async (id: string) => id,
  unauthenticated: () => Response.json({ error: "sign in" }, { status: 401 }),
  identify: async (req: Request) => {
    const h = req.headers.get("authorization") ?? "";
    const m = h.match(/^Bearer test:([^:]+)(?::(token))?$/);
    return m ? { userId: m[1], via: m[2] ? "token" : "session" } : null;
  },
}));
const { makeRoutes } = await import("./routes");
type MemMachine = Machine & { user_id: string };

function memStore(): Store {
  const machines: MemMachine[] = [];
  const tokens: { id: string; user_id: string; name: string; prefix: string; created_at: string }[] = [];
  let nextId = 1;
  const uuid = () => `00000000-0000-4000-8000-${String(nextId++).padStart(12, "0")}`;
  const insert = async (userId: string, name: string, config: MachineConfig, upsert: boolean) => {
    const existing = machines.find((m) => m.user_id === userId && m.name === name);
    if (existing && !upsert) throw new ConflictError("a machine with that name already exists");
    if (!existing && machines.filter((m) => m.user_id === userId).length >= MAX_MACHINES) throw new LimitError(`at most ${MAX_MACHINES} machines per account`);
    if (existing) { existing.config = config; existing.updated_at = new Date().toISOString(); return existing; }
    const m = { id: uuid(), user_id: userId, name, config, created_at: new Date().toISOString(), updated_at: new Date().toISOString() };
    machines.push(m); return m;
  };
  return {
    listMachines: async (u) => machines.filter((m) => m.user_id === u),
    findMachine: async (u, idOrName) => machines.find((m) => m.user_id === u && (m.id === idOrName || m.name === idOrName)) ?? null,
    createMachine: (u, n, c) => insert(u, n, c, false),
    upsertMachine: (u, n, c) => insert(u, n, c, true),
    updateMachine: async (u, id, name, config) => { const m = machines.find((x) => x.user_id === u && x.id === id); if (!m) return null; m.name = name; m.config = config; return m; },
    deleteMachine: async (u, id) => { const i = machines.findIndex((x) => x.user_id === u && x.id === id); if (i < 0) return false; machines.splice(i, 1); return true; },
    listTokens: async (u) => tokens.filter((t) => t.user_id === u),
    createToken: async (u, name, prefix) => {
      if (tokens.filter((t) => t.user_id === u).length >= MAX_TOKENS) throw new LimitError(`at most ${MAX_TOKENS} tokens per account`);
      const t = { id: uuid(), user_id: u, name, prefix, created_at: new Date().toISOString() }; tokens.push(t); return t;
    },
    deleteToken: async (u, id) => { const i = tokens.findIndex((t) => t.user_id === u && t.id === id); if (i >= 0) tokens.splice(i, 1); },
  } as Store;
}

type Handler = (req: Request & { params: Record<string, string> }) => Promise<Response> | Response;
function call(routes: ReturnType<typeof makeRoutes>, method: string, path: string, user: string | null, body?: unknown, opts: { token?: boolean; raw?: string; headers?: Record<string, string> } = {}) {
  const key = Object.keys(routes).find((k) => k !== "/api/*" && new RegExp("^" + k.replace(/:[a-z]+/g, "([^/]+)") + "$").test(path))!;
  const m = path.match(new RegExp("^" + key.replace(/:[a-z]+/g, "([^/]+)") + "$"))!;
  const names = [...key.matchAll(/:([a-z]+)/g)].map((x) => x[1]);
  const params = Object.fromEntries(names.map((n, i) => [n, m[i + 1]]));
  const entry = routes[key as keyof typeof routes] as Handler | Record<string, Handler>;
  const handler = typeof entry === "function" ? entry : entry[method];
  const headers: Record<string, string> = { ...(opts.headers ?? {}) };
  if (user) headers.authorization = `Bearer test:${user}${opts.token ? ":token" : ""}`;
  const init: RequestInit = { method, headers };
  if (opts.raw !== undefined) init.body = opts.raw;
  else if (body !== undefined) { init.body = JSON.stringify(body); headers["content-type"] = "application/json"; }
  const req = new Request("http://test" + path, init) as Request & { params: Record<string, string> };
  req.params = params;
  return Promise.resolve(handler(req));
}

describe("machines", () => {
  test("create, duplicate create conflicts, ini upsert replaces", async () => {
    const r = makeRoutes(memStore());
    expect((await call(r, "POST", "/api/machines", "a", { name: "mac1", config: {} })).status).toBe(201);
    expect((await call(r, "POST", "/api/machines", "a", { name: "mac1", config: {} })).status).toBe(409);
    const put = await call(r, "PUT", "/api/machines/mac1/ini", "a", undefined, { raw: "[display]\nscale=1.5\n" });
    expect(put.status).toBe(200);
    const got = await (await call(r, "GET", "/api/machines/mac1", "a")).json();
    expect(got.config.display.scale).toBe("1.5");
  });
  test("both creation routes stop at the limit, also concurrently", async () => {
    const r = makeRoutes(memStore());
    for (let i = 0; i < MAX_MACHINES - 1; i++) expect((await call(r, "POST", "/api/machines", "a", { name: "m" + i, config: {} })).status).toBe(201);
    const results = await Promise.all([
      call(r, "POST", "/api/machines", "a", { name: "x1", config: {} }),
      call(r, "POST", "/api/machines", "a", { name: "x2", config: {} }),
      call(r, "PUT", "/api/machines/x3/ini", "a", undefined, { raw: "[display]\nscale=1\n" }),
    ]);
    const ok = results.filter((x) => x.status < 300).length;
    expect(ok).toBe(1);
    expect(results.filter((x) => x.status === 409).length).toBe(2);
    // an ini upsert of an existing machine is still allowed at the cap
    expect((await call(r, "PUT", "/api/machines/m0/ini", "a", undefined, { raw: "[display]\nscale=2\n" })).status).toBe(200);
  });
  test("invalid configuration is a 422 with problems, malformed JSON a 400, oversized a 413", async () => {
    const r = makeRoutes(memStore());
    const bad = await call(r, "POST", "/api/machines", "a", { name: "m", config: { display: { scale: "0" } } });
    expect(bad.status).toBe(422);
    expect((await bad.json()).problems[0]).toMatch(/display.scale/);
    expect((await call(r, "POST", "/api/machines", "a", undefined, { raw: "{not json" })).status).toBe(400);
    const big = await call(r, "POST", "/api/machines", "a", undefined, { raw: "x".repeat(300 * 1024), headers: { "content-length": String(300 * 1024) } });
    expect(big.status).toBe(413);
    const bigIni = await call(r, "PUT", "/api/machines/m/ini", "a", undefined, { raw: "x".repeat(70 * 1024) });
    expect(bigIni.status).toBe(413);
    expect((await call(r, "POST", "/api/machines", "a", { name: "../etc", config: {} })).status).toBe(400);
  });
  test("ini upload with bad values keeps stored values and reports problems", async () => {
    const r = makeRoutes(memStore());
    await call(r, "POST", "/api/machines", "a", { name: "m", config: { display: { scale: "2" } } });
    const put = await (await call(r, "PUT", "/api/machines/m/ini", "a", undefined, { raw: "[display]\nscale=0\n[__proto__]\nx=1\n" })).json();
    expect(put.ok).toBe(true);
    expect(put.problems.length).toBeGreaterThan(0);
    const got = await (await call(r, "GET", "/api/machines/m", "a")).json();
    expect(got.config.display.scale).toBe("2");
  });
  test("user A can not see, change or delete user B's machines, with sessions or tokens", async () => {
    const r = makeRoutes(memStore());
    const created = await (await call(r, "POST", "/api/machines", "b", { name: "secret", config: {} })).json();
    for (const token of [false, true]) {
      expect((await call(r, "GET", "/api/machines/secret", "a", undefined, { token })).status).toBe(404);
      expect((await call(r, "GET", "/api/machines/" + created.id, "a", undefined, { token })).status).toBe(404);
      expect((await call(r, "PUT", "/api/machines/" + created.id, "a", { name: "stolen" }, { token })).status).toBe(404);
      expect((await call(r, "DELETE", "/api/machines/" + created.id, "a", undefined, { token })).status).toBe(404);
      expect((await call(r, "GET", "/api/machines/secret/ini", "a", undefined, { token })).status).toBe(404);
    }
    expect((await call(r, "GET", "/api/machines", "a")).status).toBe(200);
    expect(await (await call(r, "GET", "/api/machines", "a")).json()).toEqual([]);
    expect((await call(r, "GET", "/api/machines", null)).status).toBe(401);
  });
});

describe("tokens", () => {
  test("limit holds under concurrent creation and tokens need a session", async () => {
    const r = makeRoutes(memStore());
    expect((await call(r, "POST", "/api/tokens", "a", { name: "t" }, { token: true })).status).toBe(403);
    const results = await Promise.all(Array.from({ length: MAX_TOKENS + 5 }, (_, i) => call(r, "POST", "/api/tokens", "a", { name: "t" + i })));
    expect(results.filter((x) => x.status === 201).length).toBe(MAX_TOKENS);
    expect(results.filter((x) => x.status === 409).length).toBe(5);
    const first = await results[0].json();
    expect(first.token.startsWith("mlx_")).toBe(true);
  });
});
