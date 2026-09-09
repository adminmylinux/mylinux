import { useEffect, useState } from "react";
import { api, type Token } from "./api";

const when = (iso: string | null) => (iso ? new Date(iso).toLocaleString() : "never");

export function Tokens() {
  const [list, setList] = useState<Token[] | null>(null);
  const [name, setName] = useState("");
  const [fresh, setFresh] = useState<Token | null>(null);
  const [error, setError] = useState("");

  const load = () => api<Token[]>("/api/tokens").then(setList).catch((e) => setError(e.message));
  useEffect(() => { load(); }, []);

  async function create(e: React.FormEvent) {
    e.preventDefault();
    setError("");
    try {
      const t = await api<Token>("/api/tokens", { method: "POST", body: JSON.stringify({ name }) });
      setFresh(t); setName(""); load();
    } catch (err) { setError((err as Error).message); }
  }

  async function revoke(t: Token) {
    if (!confirm(`Revoke the token "${t.name}"? Scripts using it stop working.`)) return;
    await api(`/api/tokens/${t.id}`, { method: "DELETE" });
    load();
  }

  return (
    <>
      <p className="muted">A token lets a script inside myLinux read and write your machine profiles with curl. Treat it like a password.</p>
      <form className="panel card row" onSubmit={create}>
        <input type="text" placeholder="What is this token for, e.g. macbook sync" value={name} onChange={(e) => setName(e.target.value)} style={{ flex: 1, minWidth: 220 }} />
        <button className="btn primary">Create token</button>
      </form>
      {error && <div className="notice error" style={{ marginBottom: 16 }}>{error}</div>}
      {fresh && (
        <div className="notice ok" style={{ marginBottom: 16 }}>
          <strong>Copy the token now.</strong> It is shown only once; the site keeps a hash.
          <div className="tokenbox">{fresh.token}</div>
          <pre className="term" style={{ padding: "6px 0 0", fontSize: 12.5 }}>{`curl -sf -H "Authorization: Bearer ${fresh.token}" https://mylinux.app/api/machines/<name>/ini -o share/mylinux.ini`}</pre>
        </div>
      )}
      {list === null ? <div className="empty">Loading…</div> : list.length === 0 ? (
        <div className="empty">No tokens yet.</div>
      ) : (
        <div className="list">
          {list.map((t) => (
            <div className="panel" key={t.id}>
              <div className="grow">
                <div className="name">{t.name} <span className="mono muted" style={{ fontWeight: 400 }}>{t.prefix}…</span></div>
                <div className="meta">created {when(t.created_at)} · last used {when(t.last_used_at)}</div>
              </div>
              <button className="btn small danger" onClick={() => revoke(t)}>Revoke</button>
            </div>
          ))}
        </div>
      )}
    </>
  );
}
