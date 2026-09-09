import { ClerkProvider, useAuth } from "@clerk/react";
import { useEffect, useState } from "react";
import { createRoot } from "react-dom/client";
import { App, NotConfigured } from "./App";
import { setTokenProvider } from "./api";

/** Hands Clerk's getToken to the api module so every request carries the session. */
function TokenBridge({ children }: { children: React.ReactNode }) {
  const { getToken, isLoaded } = useAuth();
  const [ready, setReady] = useState(false);
  useEffect(() => {
    if (!isLoaded) return;
    setTokenProvider(() => getToken());
    setReady(true);
  }, [isLoaded, getToken]);
  return ready ? <>{children}</> : null;
}

const appearance = {
  variables: {
    colorBackground: "#1e2330",
    colorInputBackground: "rgba(0,0,0,0.25)",
    colorText: "#eceff4",
    colorTextSecondary: "#a3acbd",
    colorInputText: "#eceff4",
    colorPrimary: "#2f7cf6",
    colorNeutral: "#eceff4",
    borderRadius: "10px",
    fontFamily: "Inter, system-ui, sans-serif",
  },
  elements: {
    cardBox: { boxShadow: "0 30px 80px rgba(0,0,0,.45)", border: "1px solid rgba(255,255,255,.12)" },
    footer: { background: "rgba(255,255,255,.04)" },
  },
};

async function boot() {
  const root = createRoot(document.getElementById("root")!);
  let key: string | null = null;
  try {
    key = (await fetch("/api/config").then((r) => r.json())).clerkPublishableKey ?? null;
  } catch { /* server unreachable: fall through to the notice */ }
  if (!key) {
    root.render(<NotConfigured />);
    return;
  }
  root.render(
    <ClerkProvider
      publishableKey={key}
      afterSignOutUrl="/"
      signInUrl="/sign-in"
      signUpUrl="/sign-up"
      signInFallbackRedirectUrl="/app"
      signUpFallbackRedirectUrl="/app"
      appearance={appearance}
    >
      <TokenBridge>
        <App />
      </TokenBridge>
    </ClerkProvider>,
  );
}

boot();
