export type MachineConfig = {
  display: { scale: string; brightness: string; textScale: string; terminalFontPt: string };
  input: { layout: string };
  theme: { id: string; background: string };
  session: { autostart: string[] };
  packages: string[];
  notes: string;
  extra: Record<string, Record<string, string>>;
};
export type Machine = { id: string; name: string; config: MachineConfig; created_at: string; updated_at: string };
export type Token = { id: string; name: string; prefix: string; created_at: string; last_used_at: string | null; token?: string };

export class ApiError extends Error {
  constructor(public status: number, message: string) { super(message); }
}

/** Set once Clerk is up: returns the session token for the Authorization header. */
export let tokenProvider: () => Promise<string | null> = async () => null;
export const setTokenProvider = (fn: typeof tokenProvider) => { tokenProvider = fn; };

export async function api<T>(path: string, init: RequestInit = {}): Promise<T> {
  const headers = new Headers(init.headers);
  const token = await tokenProvider().catch(() => null);
  if (token) headers.set("Authorization", `Bearer ${token}`);
  if (init.body && typeof init.body === "string" && !headers.has("content-type")) headers.set("content-type", "application/json");
  const r = await fetch(path, { ...init, headers });
  const isText = r.headers.get("content-type")?.startsWith("text/plain");
  const data = isText ? await r.text() : await r.json().catch(() => ({}));
  if (!r.ok) throw new ApiError(r.status, (data as { message?: string; error?: string }).message ?? (data as { error?: string }).error ?? r.statusText);
  return data as T;
}
