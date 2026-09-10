/** The guest keeps its settings in share/mylinux.ini (Qt QSettings ini). The account stores the
 * same sections as JSON so the web form and the ini file round-trip without loss of the keys the
 * shell reads. Unknown sections and keys are kept under "extra".
 *
 * Contract (validated on every path in, enforced again by the shell on the guest):
 *   display.scale 0.5..3, display.textScale 0.5..3, display.brightness 0.2..1, terminalFontPt 6..40
 *   input.layout one of LAYOUTS ("en" from old profiles is migrated to "us")
 *   theme.id [a-z0-9][a-z0-9._-]{0,63}, theme.background integer >= 0
 *   session.autostart, packages: up to 64 entries of printable text without newlines
 *   notes: up to 20000 characters
 *   extra: up to 32 sections x 64 keys, names [A-Za-z0-9_.-], values printable single lines;
 *          the managed sections/keys above can not be shadowed through extra.
 * Unsupported on purpose: multi-line values, keys or values containing control characters, section
 * names with brackets, "__proto__"/"constructor"/"prototype" anywhere. */

export type MachineConfig = {
  display: { scale: string; brightness: string; textScale: string; terminalFontPt: string };
  input: { layout: string };
  theme: { id: string; background: string };
  session: { autostart: string[] };
  packages: string[];
  notes: string;
  extra: Record<string, Record<string, string>>;
};

export const LAYOUTS = ["us", "no", "is"] as const;
const LAYOUT_ALIASES: Record<string, string> = { en: "us", "en-us": "us", english: "us", nb: "no", norwegian: "no", icelandic: "is" };

export const emptyConfig = (): MachineConfig => ({
  display: { scale: "1", brightness: "1", textScale: "1", terminalFontPt: "10" },
  input: { layout: "us" },
  theme: { id: "tokyo-night", background: "1" },
  session: { autostart: ["/usr/bin/claude-web", "/usr/bin/chatgpt"] },
  packages: [],
  notes: "",
  extra: {},
});

export class ConfigError extends Error {
  constructor(public readonly problems: string[]) {
    super(problems.join("; "));
  }
}

// ---- primitives ----------------------------------------------------------------------------------
const FORBIDDEN_NAMES = new Set(["__proto__", "constructor", "prototype"]);
const NAME_RE = /^[A-Za-z0-9_][A-Za-z0-9_.-]{0,63}$/;
const THEME_RE = /^[a-z0-9][a-z0-9._-]{0,63}$/;
const MAX_EXTRA_SECTIONS = 32, MAX_EXTRA_KEYS = 64, MAX_VALUE = 1024, MAX_LIST = 64, MAX_NOTES = 20000;

/** A plain object with no prototype: keys like "__proto__" are ordinary own properties. */
const dict = <T>(): Record<string, T> => Object.create(null) as Record<string, T>;
const own = (o: object, k: string) => Object.prototype.hasOwnProperty.call(o, k);
export const safeName = (n: unknown): n is string => typeof n === "string" && NAME_RE.test(n) && !FORBIDDEN_NAMES.has(n.toLowerCase());
const printable = (s: string) => !/[\u0000-\u0008\u000a-\u001f\u007f]/.test(s);   // tab allowed, newlines not

const MANAGED: Record<string, readonly string[]> = {
  display: ["scale", "brightness", "textScale", "terminalFontPt"],
  input: ["layout"],
  theme: ["id", "background"],
  session: ["autostart"],
  packages: ["list"],
};

// ---- field validators: each returns the canonical string or throws --------------------------------
const num = (v: unknown, what: string, min: number, max: number, integer = false): string => {
  const s = typeof v === "number" ? String(v) : typeof v === "string" ? v.trim() : "";
  if (!/^-?\d+(\.\d+)?$/.test(s)) throw new ConfigError([`${what}: not a number`]);
  const n = Number(s);
  if (!Number.isFinite(n) || n < min || n > max) throw new ConfigError([`${what}: must be between ${min} and ${max}`]);
  if (integer && !Number.isInteger(n)) throw new ConfigError([`${what}: must be a whole number`]);
  return String(n);
};
const layout = (v: unknown): string => {
  const s = typeof v === "string" ? v.trim().toLowerCase() : "";
  const l = LAYOUT_ALIASES[s] ?? s;
  if (!(LAYOUTS as readonly string[]).includes(l)) throw new ConfigError([`input.layout: unknown layout "${s}"`]);
  return l;
};
const themeId = (v: unknown): string => {
  const s = typeof v === "string" ? v.trim() : "";
  if (!THEME_RE.test(s)) throw new ConfigError(["theme.id: letters, digits, dot, dash, underscore, up to 64 characters"]);
  return s;
};
const line = (v: unknown, what: string, max = MAX_VALUE): string => {
  const s = typeof v === "string" ? v : typeof v === "number" ? String(v) : "";
  if (!printable(s)) throw new ConfigError([`${what}: control characters or line breaks are not allowed`]);
  if (s.length > max) throw new ConfigError([`${what}: longer than ${max} characters`]);
  return s;
};
const list = (v: unknown, what: string): string[] => {
  if (v === undefined || v === null) return [];
  const arr = Array.isArray(v) ? v : typeof v === "string" ? v.split(",") : null;
  if (!arr) throw new ConfigError([`${what}: must be a list`]);
  const out = arr.map((s, i) => line(s, `${what}[${i}]`, 512).trim()).filter(Boolean);
  if (out.length > MAX_LIST) throw new ConfigError([`${what}: more than ${MAX_LIST} entries`]);
  return out;
};

/** Validate arbitrary input into a well-formed config. Throws ConfigError listing every problem. */
export function normalizeConfig(raw: unknown): MachineConfig {
  const base = emptyConfig();
  const r = (raw && typeof raw === "object" && !Array.isArray(raw) ? raw : {}) as Record<string, unknown>;
  const sec = (k: string) => (own(r, k) && r[k] && typeof r[k] === "object" ? (r[k] as Record<string, unknown>) : {});
  const d = sec("display"), i = sec("input"), t = sec("theme"), s = sec("session");
  const pick = (o: Record<string, unknown>, k: string, fallback: string) => (own(o, k) && o[k] !== undefined && o[k] !== "" ? o[k] : fallback);
  const problems: string[] = [];
  const attempt = <T>(fn: () => T, fallback: T): T => {
    try { return fn(); } catch (e) { if (e instanceof ConfigError) problems.push(...e.problems); else throw e; return fallback; }
  };
  const out: MachineConfig = {
    display: {
      scale: attempt(() => num(pick(d, "scale", base.display.scale), "display.scale", 0.5, 3), base.display.scale),
      brightness: attempt(() => num(pick(d, "brightness", base.display.brightness), "display.brightness", 0.2, 1), base.display.brightness),
      textScale: attempt(() => num(pick(d, "textScale", base.display.textScale), "display.textScale", 0.5, 3), base.display.textScale),
      terminalFontPt: attempt(() => num(pick(d, "terminalFontPt", base.display.terminalFontPt), "display.terminalFontPt", 6, 40, true), base.display.terminalFontPt),
    },
    input: { layout: attempt(() => layout(pick(i, "layout", base.input.layout)), base.input.layout) },
    theme: {
      id: attempt(() => themeId(pick(t, "id", base.theme.id)), base.theme.id),
      background: attempt(() => num(pick(t, "background", base.theme.background), "theme.background", 0, 999, true), base.theme.background),
    },
    session: { autostart: attempt(() => list(own(s, "autostart") ? s.autostart : undefined, "session.autostart"), []) },
    packages: attempt(() => list(own(r, "packages") ? r.packages : undefined, "packages"), []),
    notes: attempt(() => { const n = typeof r.notes === "string" ? r.notes : ""; if (n.length > MAX_NOTES) throw new ConfigError([`notes: longer than ${MAX_NOTES} characters`]); return n; }, ""),
    extra: {},
  };
  const extra = dict<Record<string, string>>();
  if (own(r, "extra") && r.extra && typeof r.extra === "object" && !Array.isArray(r.extra)) {
    const sections = Object.keys(r.extra as object);
    if (sections.length > MAX_EXTRA_SECTIONS) problems.push(`extra: more than ${MAX_EXTRA_SECTIONS} sections`);
    for (const name of sections.slice(0, MAX_EXTRA_SECTIONS)) {
      if (!safeName(name)) { problems.push(`extra: bad section name "${String(name).slice(0, 40)}"`); continue; }
      const kv = (r.extra as Record<string, unknown>)[name];
      if (!kv || typeof kv !== "object" || Array.isArray(kv)) { problems.push(`extra.${name}: must be a table`); continue; }
      const keys = Object.keys(kv as object);
      if (keys.length > MAX_EXTRA_KEYS) problems.push(`extra.${name}: more than ${MAX_EXTRA_KEYS} keys`);
      const section = dict<string>();
      for (const k of keys.slice(0, MAX_EXTRA_KEYS)) {
        if (!safeName(k)) { problems.push(`extra.${name}: bad key name "${String(k).slice(0, 40)}"`); continue; }
        if (own(MANAGED, name) && MANAGED[name].includes(k)) { problems.push(`extra.${name}.${k}: managed key, set it in its own field`); continue; }
        section[k] = attempt(() => line((kv as Record<string, unknown>)[k], `extra.${name}.${k}`), "");
      }
      if (Object.keys(section).length) extra[name] = section;
    }
  }
  // freeze into ordinary (prototype-less) objects so JSON/DB round trips stay plain
  out.extra = extra;
  if (problems.length) throw new ConfigError(problems);
  return out;
}

/** Like normalizeConfig, but returns {config, problems} instead of throwing: every offending field is
 * replaced by the value from `fallback` (the previous config, or the defaults) and reported. */
export function tryNormalize(raw: unknown, fallback: MachineConfig = emptyConfig()): { config: MachineConfig; problems: string[] } {
  let current = raw;
  const problems: string[] = [];
  for (let round = 0; round < 4; round++) {
    try { return { config: normalizeConfig(current), problems }; }
    catch (e) {
      if (!(e instanceof ConfigError)) throw e;
      problems.push(...e.problems);
      current = replaceInvalid(current, e.problems, fallback);
    }
  }
  return { config: normalizeConfig(fallback), problems };
}
function replaceInvalid(raw: unknown, problems: string[], fallback: MachineConfig): unknown {
  const r = (raw && typeof raw === "object" ? { ...(raw as object) } : {}) as Record<string, unknown>;
  const fb = fallback as unknown as Record<string, Record<string, unknown>>;
  for (const p of problems) {
    const head = p.split(":")[0].trim();
    if (head.startsWith("extra")) { r.extra = fallback.extra; continue; }
    const [sec, key] = head.replace(/\[\d+\]$/, "").split(".");
    if (key && r[sec] && typeof r[sec] === "object") r[sec] = { ...(r[sec] as object), [key]: fb[sec]?.[key] };
    else r[sec] = fb[sec];
  }
  return r;
}

// ---- ini text ------------------------------------------------------------------------------------
/** Serialize to QSettings ini. Values were validated as single printable lines, so nothing here can
 * open a new section or key. Commas are escaped for QSettings' list syntax; quotes are kept as-is
 * because QSettings reads an unquoted line verbatim. */
export function toIni(c: MachineConfig): string {
  const enc = (v: string) => v.replace(/\\/g, "\\\\").replace(/,/g, "\\,").replace(/\r?\n/g, " ");
  const sections: [string, Record<string, string>][] = [
    ["display", { ...c.display }],
    ["input", { ...c.input }],
    ["theme", { ...c.theme }],
    ["session", { autostart: c.session.autostart.map(enc).join(",") }],
  ];
  if (c.packages.length) sections.push(["packages", { list: c.packages.map(enc).join(",") }]);
  const known = new Map(sections);
  for (const [name, kv] of Object.entries(c.extra)) {
    if (!safeName(name)) continue;
    const target = known.get(name) ?? dict<string>();
    for (const [k, v] of Object.entries(kv)) {
      if (!safeName(k) || (own(MANAGED, name) && MANAGED[name].includes(k))) continue;
      target[k] = v;
    }
    if (!known.has(name)) { known.set(name, target); sections.push([name, target]); }
  }
  const lines: string[] = [];
  for (const [name, kv] of sections) {
    lines.push(`[${name}]`);
    for (const [k, v] of Object.entries(kv)) lines.push(`${k}=${name === "session" || name === "packages" ? v : enc(v)}`);
    lines.push("");
  }
  return lines.join("\n");
}

/** Parse an ini text into a config. Malformed lines are ignored; bad values fall back to the
 * previous (or default) value and are reported in `problems`. */
export function fromIni(text: string, previous?: MachineConfig): { config: MachineConfig; problems: string[] } {
  const raw: Record<string, unknown> = dict();
  const base = previous ?? emptyConfig();
  raw.display = { ...base.display }; raw.input = { ...base.input }; raw.theme = { ...base.theme };
  raw.session = { autostart: [...base.session.autostart] }; raw.packages = [...base.packages]; raw.notes = base.notes;
  const extra = dict<Record<string, string>>();
  const dec = (v: string) => v.replace(/\\,/g, "\u0000").replace(/\\\\/g, "\\").split("\u0000").join(",");
  const splitList = (v: string) => v.replace(/\\\\/g, "\u0001").split(/(?<!\\),/).map((s) => s.replace(/\\,/g, ",").replace(/\u0001/g, "\\").trim()).filter(Boolean);
  const problems: string[] = [];
  let current = "";
  let lineNo = 0;
  for (const rawLine of text.split(/\r?\n/)) {
    lineNo++;
    const l = rawLine.trim();
    if (!l || l.startsWith(";") || l.startsWith("#")) continue;
    const sec = l.match(/^\[([^\]]+)\]$/);
    if (sec) {
      const name = sec[1].trim();
      if (!safeName(name)) { problems.push(`line ${lineNo}: section name not allowed`); current = ""; continue; }
      current = name; continue;
    }
    const eq = l.indexOf("=");
    if (eq <= 0 || !current) continue;
    const k = l.slice(0, eq).trim();
    const v = l.slice(eq + 1).trim();
    if (!safeName(k)) { problems.push(`line ${lineNo}: key name not allowed`); continue; }
    if (own(MANAGED, current) && MANAGED[current].includes(k)) {
      if (current === "session") (raw.session as { autostart: string[] }).autostart = splitList(v);
      else if (current === "packages") raw.packages = splitList(v);
      else (raw[current] as Record<string, string>)[k] = dec(v);
    } else {
      (extra[current] ??= dict<string>())[k] = dec(v);
    }
  }
  raw.extra = extra;
  const r = tryNormalize(raw, base);
  return { config: r.config, problems: [...problems, ...r.problems] };
}
