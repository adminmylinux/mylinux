/** The guest keeps its settings in share/mylinux.ini (Qt QSettings ini). The
 * account stores the same sections as JSON so the web form and the ini file
 * round-trip without loss of the keys the shell reads. Unknown sections and
 * keys are kept verbatim under "extra". */

export type MachineConfig = {
  display: { scale: string; brightness: string; textScale: string; terminalFontPt: string };
  input: { layout: string };
  theme: { id: string; background: string };
  session: { autostart: string[] };
  packages: string[];
  notes: string;
  extra: Record<string, Record<string, string>>;
};

export const emptyConfig = (): MachineConfig => ({
  display: { scale: "1", brightness: "1", textScale: "1", terminalFontPt: "10" },
  input: { layout: "en" },
  theme: { id: "tokyo-night", background: "1" },
  session: { autostart: ["/usr/bin/claude-web", "/usr/bin/chatgpt"] },
  packages: [],
  notes: "",
  extra: {},
});

const str = (v: unknown, fallback: string) =>
  typeof v === "string" ? v : typeof v === "number" ? String(v) : fallback;
const strList = (v: unknown): string[] =>
  Array.isArray(v) ? v.filter((s): s is string => typeof s === "string").map((s) => s.trim()).filter(Boolean) : [];

/** Accept whatever the client sent and return a well-formed config. */
export function normalizeConfig(raw: unknown): MachineConfig {
  const base = emptyConfig();
  const r = (raw && typeof raw === "object" ? raw : {}) as Record<string, any>;
  const d = r.display ?? {}, i = r.input ?? {}, t = r.theme ?? {}, s = r.session ?? {};
  const extra: MachineConfig["extra"] = {};
  if (r.extra && typeof r.extra === "object") {
    for (const [sec, kv] of Object.entries(r.extra as Record<string, unknown>)) {
      if (!kv || typeof kv !== "object") continue;
      extra[sec] = {};
      for (const [k, v] of Object.entries(kv as Record<string, unknown>)) extra[sec][k] = str(v, "");
    }
  }
  return {
    display: {
      scale: str(d.scale, base.display.scale),
      brightness: str(d.brightness, base.display.brightness),
      textScale: str(d.textScale, base.display.textScale),
      terminalFontPt: str(d.terminalFontPt, base.display.terminalFontPt),
    },
    input: { layout: str(i.layout, base.input.layout) },
    theme: { id: str(t.id, base.theme.id), background: str(t.background, base.theme.background) },
    session: { autostart: strList(s.autostart) },
    packages: strList(r.packages),
    notes: str(r.notes, "").slice(0, 20000),
    extra,
  };
}

export function toIni(c: MachineConfig): string {
  // known sections first, extra keys of a known section merged into it
  const sections: Record<string, Record<string, string>> = {
    display: { ...c.display },
    input: { ...c.input },
    theme: { ...c.theme },
    session: { autostart: c.session.autostart.join(",") },
  };
  if (c.packages.length) sections.packages = { list: c.packages.join(",") };
  for (const [name, kv] of Object.entries(c.extra)) sections[name] = { ...(sections[name] ?? {}), ...kv };
  const lines: string[] = [];
  for (const [name, kv] of Object.entries(sections)) {
    lines.push(`[${name}]`);
    for (const [k, v] of Object.entries(kv)) lines.push(`${k}=${v}`);
    lines.push("");
  }
  return lines.join("\n");
}

/** Parse an ini text into a config; sections the shell does not know go to extra. */
export function fromIni(text: string, previous?: MachineConfig): MachineConfig {
  const c = previous ? structuredClone(previous) : emptyConfig();
  c.extra = {};
  let current = "";
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith(";") || line.startsWith("#")) continue;
    const sec = line.match(/^\[(.+)\]$/);
    if (sec) { current = sec[1].trim(); continue; }
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const k = line.slice(0, eq).trim();
    const v = line.slice(eq + 1).trim();
    switch (current) {
      case "display":
        if (k in c.display) (c.display as Record<string, string>)[k] = v;
        else (c.extra.display ??= {})[k] = v;
        break;
      case "input":
        if (k === "layout") c.input.layout = v; else (c.extra.input ??= {})[k] = v;
        break;
      case "theme":
        if (k === "id" || k === "background") c.theme[k] = v; else (c.extra.theme ??= {})[k] = v;
        break;
      case "session":
        if (k === "autostart") c.session.autostart = v.split(",").map((s) => s.trim()).filter(Boolean);
        else (c.extra.session ??= {})[k] = v;
        break;
      case "packages":
        if (k === "list") c.packages = v.split(/[,\s]+/).map((s) => s.trim()).filter(Boolean);
        else (c.extra.packages ??= {})[k] = v;
        break;
      default:
        if (current) (c.extra[current] ??= {})[k] = v;
    }
  }
  return normalizeConfig(c);
}
