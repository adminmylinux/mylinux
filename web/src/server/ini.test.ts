import { describe, expect, test } from "bun:test";
import { ConfigError, emptyConfig, fromIni, normalizeConfig, toIni } from "./ini";

describe("prototype safety", () => {
  test("hostile ini sections and keys never touch shared prototypes", () => {
    const probe = "mylinuxReviewProbe" + Math.random().toString(36).slice(2);
    const r = fromIni(`[__proto__]\n${probe}=1\n[constructor]\nprototype=2\n[display]\n__proto__=3\n`);
    expect(({} as Record<string, unknown>)[probe]).toBeUndefined();
    expect((Object.prototype as Record<string, unknown>)[probe]).toBeUndefined();
    expect(r.problems.length).toBeGreaterThan(0);
    expect(Object.keys(r.config.extra)).toEqual([]);
  });
  test("hostile JSON extra is rejected, prototypes unchanged", () => {
    const probe = "mylinuxJsonProbe" + Math.random().toString(36).slice(2);
    const raw = JSON.parse(`{"extra":{"__proto__":{"${probe}":"1"},"ok":{"a":"b"}}}`);
    expect(() => normalizeConfig(raw)).toThrow(ConfigError);
    expect(({} as Record<string, unknown>)[probe]).toBeUndefined();
  });
});

describe("contract", () => {
  test("defaults are valid and use the us layout", () => {
    const c = normalizeConfig(emptyConfig());
    expect(c.input.layout).toBe("us");
    expect(c.display.scale).toBe("1");
  });
  test("numbers are bounded and finite", () => {
    for (const bad of [{ display: { scale: "0" } }, { display: { brightness: "-3" } }, { display: { scale: "NaN" } },
                       { display: { scale: "Infinity" } }, { display: { scale: "1e309" } }, { theme: { background: "-1" } },
                       { display: { terminalFontPt: "10.5" } }]) {
      expect(() => normalizeConfig(bad)).toThrow(ConfigError);
    }
    expect(normalizeConfig({ display: { scale: 1.5, brightness: "0.7" } }).display.scale).toBe("1.5");
  });
  test("layouts: aliases migrate, unknown rejected", () => {
    expect(normalizeConfig({ input: { layout: "en" } }).input.layout).toBe("us");
    expect(normalizeConfig({ input: { layout: "NO" } }).input.layout).toBe("no");
    expect(() => normalizeConfig({ input: { layout: "invalid" } })).toThrow(ConfigError);
  });
  test("theme id and lists are constrained", () => {
    expect(() => normalizeConfig({ theme: { id: "../x" } })).toThrow(ConfigError);
    expect(() => normalizeConfig({ session: { autostart: new Array(65).fill("/usr/bin/foot") } })).toThrow(ConfigError);
    expect(normalizeConfig({ session: { autostart: [] } }).session.autostart).toEqual([]);
    expect(normalizeConfig({ packages: "git, btop ,, " }).packages).toEqual(["git", "btop"]);
  });
  test("extra can not shadow managed keys and rejects bad names", () => {
    expect(() => normalizeConfig({ extra: { display: { scale: "9" } } })).toThrow(/managed key/);
    expect(() => normalizeConfig({ extra: { "bad name": { a: "b" } } })).toThrow(/bad section/);
    const c = normalizeConfig({ extra: { look: { solidPanels: "false" }, wm: { titlebars: "never" } } });
    expect(c.extra.look.solidPanels).toBe("false");
    expect(c.extra.wm.titlebars).toBe("never");
  });
  test("every problem is reported at once", () => {
    try { normalizeConfig({ display: { scale: "0" }, input: { layout: "xx" } }); throw new Error("no throw"); }
    catch (e) { expect((e as ConfigError).problems.length).toBe(2); }
  });
});

describe("ini text", () => {
  test("injected newlines can not create sections or keys", () => {
    expect(() => normalizeConfig({ notes: "fine", extra: { x: { a: "test\n[input]\nlayout=invalid" } } })).toThrow(ConfigError);
    const c = normalizeConfig({ theme: { id: "tokyo-night" } });
    (c.theme as { id: string }).id = "x\n[input]\nlayout=no";   // bypass validation on purpose
    const ini = toIni(c);
    expect(ini.split("\n").filter((l) => l === "[input]").length).toBe(1);
    expect(fromIni(ini).config.input.layout).toBe("us");
  });
  test("extra.display.scale can not override display.scale on export", () => {
    const c = normalizeConfig({ display: { scale: "1.5" } });
    c.extra = { display: { scale: "3" } } as never;
    expect(toIni(c)).toContain("scale=1.5");
    expect(toIni(c)).not.toContain("scale=3");
  });
  test("round trip keeps quotes, commas, unicode, unknown safe keys, empty autostart and look/wm", () => {
    const c = normalizeConfig({
      display: { scale: "1.25" }, input: { layout: "no" }, theme: { id: "hackerman", background: "3" },
      session: { autostart: [] }, packages: ["git", "btop"],
      extra: { look: { solidPanels: "true", dockAutoHide: "false" }, wm: { titlebars: "auto" }, hosts: { note: 'say "hi", ok? æøå 日本' } },
    });
    const ini = toIni(c);
    const back = fromIni(ini).config;
    expect(back.display.scale).toBe("1.25");
    expect(back.input.layout).toBe("no");
    expect(back.theme).toEqual({ id: "hackerman", background: "3" });
    expect(back.session.autostart).toEqual([]);
    expect(back.packages).toEqual(["git", "btop"]);
    expect(back.extra.look).toEqual({ solidPanels: "true", dockAutoHide: "false" });
    expect(back.extra.wm).toEqual({ titlebars: "auto" });
    expect(back.extra.hosts.note).toBe('say "hi", ok? æøå 日本');
  });
  test("autostart entries with commas survive", () => {
    const c = normalizeConfig({ session: { autostart: ["/usr/bin/foot -e sh -c 'a,b'", "/usr/bin/chatgpt"] } });
    expect(fromIni(toIni(c)).config.session.autostart).toEqual(["/usr/bin/foot -e sh -c 'a,b'", "/usr/bin/chatgpt"]);
  });
  test("bad ini values fall back to the previous config and are reported", () => {
    const prev = normalizeConfig({ display: { scale: "2" } });
    const r = fromIni("[display]\nscale=0\n[input]\nlayout=en\n", prev);
    expect(r.config.display.scale).toBe("2");
    expect(r.config.input.layout).toBe("us");
    expect(r.problems.some((p) => p.startsWith("display.scale"))).toBe(true);
  });
  test("what the guest writes today parses", () => {
    const r = fromIni("[display]\nbrightness=1\nscale=1\nterminalFontPt=10\ntextScale=0.9090909090909091\n\n[input]\nlayout=no\n\n[theme]\nbackground=1\nid=hackerman\n\n[session]\nautostart=/usr/bin/claude-web,/usr/bin/chatgpt\n\n[test]\ndiag=true\n");
    expect(r.problems).toEqual([]);
    expect(r.config.display.textScale).toBe("0.9090909090909091");
    expect(r.config.extra.test.diag).toBe("true");
  });
});
