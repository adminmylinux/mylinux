import { useEffect, useState } from "react";
import { api, type Machine, type MachineConfig } from "./api";
import { go } from "./App";

const LAYOUTS = [["en", "English (US)"], ["no", "Norwegian"], ["is", "Icelandic"]];
const THEMES = ["tokyo-night", "catppuccin", "catppuccin-latte", "everforest", "gruvbox", "kanagawa", "matte-black", "nord", "osaka-jade", "ristretto", "rose-pine", "hackerman", "flexoki-light"];

function ListField({ label, hint, values, onChange, placeholder }: { label: string; hint?: string; values: string[]; onChange: (v: string[]) => void; placeholder: string }) {
  const [draft, setDraft] = useState("");
  const add = () => {
    const items = draft.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean);
    if (items.length) onChange([...values, ...items.filter((i) => !values.includes(i))]);
    setDraft("");
  };
  return (
    <label className="field">
      <span>{label}{hint && <span className="muted"> · {hint}</span>}</span>
      <div className="row">
        <input type="text" value={draft} placeholder={placeholder} onChange={(e) => setDraft(e.target.value)}
          onKeyDown={(e) => { if (e.key === "Enter") { e.preventDefault(); add(); } }} style={{ flex: 1 }} className="mono" />
        <button type="button" className="btn small" onClick={add}>Add</button>
      </div>
      <div className="chips">
        {values.map((v) => (
          <span className="chip" key={v}>{v}<button type="button" aria-label={`remove ${v}`} onClick={() => onChange(values.filter((x) => x !== v))}>×</button></span>
        ))}
      </div>
    </label>
  );
}

export function MachineEditor({ id }: { id: string }) {
  const [m, setM] = useState<Machine | null>(null);
  const [name, setName] = useState("");
  const [c, setC] = useState<MachineConfig | null>(null);
  const [ini, setIni] = useState("");
  const [status, setStatus] = useState<{ kind: "ok" | "error"; text: string } | null>(null);
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    api<Machine>(`/api/machines/${id}`).then((x) => { setM(x); setName(x.name); setC(x.config); })
      .catch((e) => setStatus({ kind: "error", text: e.message }));
  }, [id]);

  if (!c || !m) return <div className="empty">{status?.text ?? "Loading…"}</div>;

  const set = <K extends keyof MachineConfig>(k: K, v: MachineConfig[K]) => setC({ ...c, [k]: v });

  async function save() {
    setBusy(true); setStatus(null);
    try {
      const saved = await api<Machine>(`/api/machines/${m!.id}`, { method: "PUT", body: JSON.stringify({ name, config: c }) });
      setM(saved); setC(saved.config); setName(saved.name);
      setStatus({ kind: "ok", text: "Saved" });
    } catch (e) { setStatus({ kind: "error", text: (e as Error).message }); } finally { setBusy(false); }
  }

  async function importIni() {
    setBusy(true); setStatus(null);
    try {
      await api(`/api/machines/${m!.id}/ini`, { method: "PUT", body: ini, headers: { "content-type": "text/plain" } });
      const fresh = await api<Machine>(`/api/machines/${m!.id}`);
      setM(fresh); setC(fresh.config); setIni("");
      setStatus({ kind: "ok", text: "Imported. The form now shows the values from the file." });
    } catch (e) { setStatus({ kind: "error", text: (e as Error).message }); } finally { setBusy(false); }
  }

  async function download() {
    const text = await api<string>(`/api/machines/${m!.id}/ini`);
    const url = URL.createObjectURL(new Blob([text], { type: "text/plain" }));
    const a = Object.assign(document.createElement("a"), { href: url, download: "mylinux.ini" });
    a.click();
    URL.revokeObjectURL(url);
  }

  async function remove() {
    if (!confirm(`Delete the profile "${m!.name}"? This cannot be undone.`)) return;
    await api(`/api/machines/${m!.id}`, { method: "DELETE" });
    go("/app");
  }

  return (
    <form onSubmit={(e) => { e.preventDefault(); save(); }}>
      <div className="row" style={{ justifyContent: "space-between", marginBottom: 18 }}>
        <input type="text" value={name} onChange={(e) => setName(e.target.value)} className="mono" style={{ width: 260, fontSize: 16, fontWeight: 600 }}
          pattern="[A-Za-z0-9][A-Za-z0-9._-]{0,63}" required aria-label="Machine name" />
        <div className="row">
          <button type="button" className="btn" onClick={download}>Download mylinux.ini</button>
          <button className="btn primary" disabled={busy}>Save changes</button>
        </div>
      </div>
      {status && <div className={`notice ${status.kind}`} style={{ marginBottom: 16 }}>{status.text}</div>}

      <div className="panel card">
        <h3>Display and input</h3>
        <div className="grid-2">
          <label className="field"><span>Desktop scale</span><input type="text" inputMode="decimal" value={c.display.scale} onChange={(e) => set("display", { ...c.display, scale: e.target.value })} /></label>
          <label className="field"><span>Text scale</span><input type="text" inputMode="decimal" value={c.display.textScale} onChange={(e) => set("display", { ...c.display, textScale: e.target.value })} /></label>
          <label className="field"><span>Brightness</span><input type="text" inputMode="decimal" value={c.display.brightness} onChange={(e) => set("display", { ...c.display, brightness: e.target.value })} /></label>
          <label className="field"><span>Terminal font size (pt)</span><input type="text" inputMode="numeric" value={c.display.terminalFontPt} onChange={(e) => set("display", { ...c.display, terminalFontPt: e.target.value })} /></label>
          <label className="field"><span>Keyboard layout</span>
            <select value={c.input.layout} onChange={(e) => set("input", { layout: e.target.value })}>
              {LAYOUTS.map(([v, l]) => <option key={v} value={v}>{l}</option>)}
              {!LAYOUTS.some(([v]) => v === c.input.layout) && <option value={c.input.layout}>{c.input.layout}</option>}
            </select>
          </label>
        </div>
      </div>

      <div className="panel card">
        <h3>Theme</h3>
        <div className="grid-2">
          <label className="field"><span>Theme</span>
            <input type="text" list="themes" value={c.theme.id} onChange={(e) => set("theme", { ...c.theme, id: e.target.value })} className="mono" />
            <datalist id="themes">{THEMES.map((t) => <option key={t} value={t} />)}</datalist>
          </label>
          <label className="field"><span>Background number</span><input type="text" inputMode="numeric" value={c.theme.background} onChange={(e) => set("theme", { ...c.theme, background: e.target.value })} /></label>
        </div>
      </div>

      <div className="panel card">
        <h3>Session</h3>
        <ListField label="Apps that open at start" hint="full paths, in order" values={c.session.autostart} onChange={(v) => set("session", { autostart: v })} placeholder="/usr/bin/claude-code" />
        <ListField label="Debian packages you added" hint="a reminder for install <pkg> on a new Mac" values={c.packages} onChange={(v) => set("packages", v)} placeholder="neovim ripgrep" />
      </div>

      <div className="panel card">
        <h3>Notes</h3>
        <label className="field"><span>Anything about this machine: Remmina profiles, share/hosts lines, Tailscale name</span>
          <textarea value={c.notes} onChange={(e) => set("notes", e.target.value)} /></label>
      </div>

      {Object.keys(c.extra).length > 0 && (
        <div className="panel card">
          <h3>Other ini sections</h3>
          <p className="muted" style={{ fontSize: 13 }}>Kept as imported and written back into the file unchanged.</p>
          <pre className="term" style={{ padding: 0 }}>{Object.entries(c.extra).map(([s, kv]) => `[${s}]\n${Object.entries(kv).map(([k, v]) => `${k}=${v}`).join("\n")}`).join("\n\n")}</pre>
        </div>
      )}

      <div className="panel card">
        <h3>Import mylinux.ini</h3>
        <label className="field"><span>Paste the file from share/ on the Mac this machine runs on. It replaces the values above.</span>
          <textarea className="mono" value={ini} onChange={(e) => setIni(e.target.value)} placeholder={"[display]\nscale=1\n\n[theme]\nid=tokyo-night"} /></label>
        <button type="button" className="btn" disabled={busy || !ini.trim()} onClick={importIni}>Import</button>
      </div>

      <div className="row" style={{ justifyContent: "space-between" }}>
        <button type="button" className="btn danger" onClick={remove}>Delete this machine</button>
        <button className="btn primary" disabled={busy}>Save changes</button>
      </div>
    </form>
  );
}
