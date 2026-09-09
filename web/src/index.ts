import { join } from "node:path";
import app from "./app.html";
import docs from "./docs.html";
import landing from "./index.html";
import logo from "./logo.svg";
import screenshot from "./screenshot.png";
import { clerkMode, clerkPublishableKey } from "./server/auth";
import { ensureSchema } from "./server/db";
import { routes } from "./server/routes";

await ensureSchema();

const server = Bun.serve({
  port: Number(process.env.PORT ?? 3000),
  development: process.env.NODE_ENV !== "production",
  routes: {
    "/api/config": () => Response.json({ clerkPublishableKey }),
    // stable URLs for the bundled (hashed) assets: favicon, og:image, menu-bar logo in the app
    "/logo.svg": () => Response.redirect(logo, 301),
    "/screenshot.png": () => Response.redirect(screenshot, 301),
    ...routes,
    "/": landing,
    "/docs": docs,
    "/app": app,
    "/app/*": app,
    "/sign-in": app,
    "/sign-in/*": app,
    "/sign-up": app,
    "/sign-up/*": app,
  },
  // Bundled files the HTML routes do not serve themselves (hashed images).
  // They sit next to this file: dist/ in production, src/ in dev.
  async fetch(req) {
    const name = new URL(req.url).pathname.slice(1);
    if (/^[\w.-]+\.(png|svg|jpg|webp|ico|css|js|map|txt)$/.test(name)) {
      const file = Bun.file(join(import.meta.dir, name));
      if (await file.exists())
        return new Response(file, { headers: { "cache-control": "public, max-age=31536000, immutable" } });
    }
    return new Response("not found", { status: 404 });
  },
});

console.log(`mylinux.app listening on ${server.url} (sign-in ${clerkMode ? "via Clerk" : "not configured"})`);
