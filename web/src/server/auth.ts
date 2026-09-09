/** Two ways in: a Clerk browser session (cookie or "Authorization: Bearer
 * <session jwt>") and personal API tokens ("Authorization: Bearer mlx_...")
 * for scripts inside myLinux. Clerk is optional: without keys the public pages
 * work and every account route answers 503 with a clear message. */
import { createClerkClient } from "@clerk/backend";
import { ensureUser, sql } from "./db";

const secretKey = process.env.CLERK_SECRET_KEY;
const publishableKey = process.env.CLERK_PUBLISHABLE_KEY;

export const clerkMode = Boolean(secretKey && publishableKey);
export const clerkPublishableKey = clerkMode ? publishableKey! : null;

const clerk = clerkMode ? createClerkClient({ secretKey, publishableKey }) : null;

const authorizedParties = (process.env.APP_ORIGINS ?? "https://mylinux.app")
  .split(",")
  .map((s) => s.trim())
  .filter(Boolean)
  .concat(["http://localhost:3000"]);

export type Identity = { userId: string; via: "session" | "token" };

export const TOKEN_PREFIX = "mlx_";

export async function hashToken(token: string) {
  const buf = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(token));
  return Buffer.from(buf).toString("hex");
}

async function tokenIdentity(token: string): Promise<Identity | null> {
  const hash = await hashToken(token);
  const rows = await sql<{ id: string; user_id: string }[]>`
    SELECT id, user_id FROM api_tokens WHERE token_hash = ${hash}`;
  if (!rows.length) return null;
  await sql`UPDATE api_tokens SET last_used_at = now() WHERE id = ${rows[0].id}`;
  return { userId: rows[0].user_id, via: "token" };
}

async function sessionIdentity(req: Request): Promise<Identity | null> {
  if (!clerk) return null;
  try {
    const state = await clerk.authenticateRequest(req, { authorizedParties });
    if (!state.isAuthenticated) return null;
    const auth = state.toAuth();
    const userId = auth?.userId;
    if (!userId) return null;
    await ensureUser(userId);
    return { userId, via: "session" };
  } catch {
    return null;
  }
}

export async function identify(req: Request): Promise<Identity | null> {
  const header = req.headers.get("authorization") ?? "";
  const bearer = header.startsWith("Bearer ") ? header.slice(7).trim() : "";
  if (bearer.startsWith(TOKEN_PREFIX)) return tokenIdentity(bearer);
  return sessionIdentity(req);
}

/** Display name for the signed-in user, one Clerk call per user. */
const nameCache = new Map<string, string>();
export async function displayName(userId: string): Promise<string> {
  const cached = nameCache.get(userId);
  if (cached) return cached;
  if (!clerk) return userId;
  try {
    const u = await clerk.users.getUser(userId);
    const name = u.firstName || u.username || u.emailAddresses[0]?.emailAddress || userId;
    nameCache.set(userId, name);
    return name;
  } catch {
    return userId;
  }
}

export const unauthenticated = () =>
  clerkMode
    ? Response.json({ error: "not authenticated" }, { status: 401 })
    : Response.json(
        { error: "sign-in not configured", message: "Clerk keys are not set on this server yet." },
        { status: 503 },
      );
