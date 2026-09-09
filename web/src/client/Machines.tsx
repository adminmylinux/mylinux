import { useEffect, useState } from "react";
import { api, type Machine } from "./api";
import { Link, go } from "./App";

const when = (iso: string) => new Date(iso).toLocaleDateString(undefined, { day: "numeric", month: "short", year: "numeric" });

export function Machines() {
  const [list, setList] = useState<Machine[] | null>(null);
  const [name, setName] = useState("");
  const [error, setError] = useState("");
  const [busy, setBusy] = useState(false);

  const load = () => api<Machine[]>("/api/machines").then(setList).catch((e) => setError(e.message));
  useEffect(() => { load(); }, []);

  async function add(e: React.FormEvent) {
    e.preventDefault();
    setBusy(true); setError("");
    try {
      const m = await api<Machine>("/api/machines", { method: "POST", body: JSON.stringify({ name: name.trim() }) });
      go(`/app/machines/${m.id}`);
    } catch (err) {
      setError((err as Error).message);
    } finally { setBusy(false); }
  }

  return (
    <>
      <form className="panel card row" onSubmit={add}>
        <input type="text" placeholder="Machine name, for example macbook" value={name} onChange={(e) => setName(e.target.value)}
          style={{ flex: 1, minWidth: 220 }} pattern="[A-Za-z0-9][A-Za-z0-9._-]{0,63}" required />
        <button className="btn primary" disabled={busy || !name.trim()}>Add machine</button>
      </form>
      {error && <div className="notice error" style={{ marginBottom: 16 }}>{error}</div>}
      {list === null ? (
        <div className="empty">Loading…</div>
      ) : list.length === 0 ? (
        <div className="empty">
          No machines yet. Add one above, then fill in its profile or import the mylinux.ini from your share folder.
        </div>
      ) : (
        <div className="list">
          {list.map((m) => (
            <Link key={m.id} to={`/app/machines/${m.id}`} className="panel" style={{ color: "inherit", textDecoration: "none" }}>
              <div className="grow">
                <div className="name">{m.name}</div>
                <div className="meta">
                  theme {m.config.theme.id} · layout {m.config.input.layout} · {m.config.packages.length} package{m.config.packages.length === 1 ? "" : "s"} · updated {when(m.updated_at)}
                </div>
              </div>
              <span className="muted">Open</span>
            </Link>
          ))}
        </div>
      )}
    </>
  );
}
