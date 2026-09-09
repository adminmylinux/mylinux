import { Show, SignIn, SignUp, UserButton, useUser } from "@clerk/react";
import { useEffect, useState } from "react";
import { MachineEditor } from "./MachineEditor";
import { Machines } from "./Machines";
import { Tokens } from "./Tokens";

/** Tiny path router: pushState + popstate, links call go(). */
export function usePath() {
  const [path, setPath] = useState(location.pathname);
  useEffect(() => {
    const on = () => setPath(location.pathname);
    addEventListener("popstate", on);
    return () => removeEventListener("popstate", on);
  }, []);
  return path;
}
export function go(to: string) {
  history.pushState(null, "", to);
  dispatchEvent(new PopStateEvent("popstate"));
}
export function Link({ to, children, ...rest }: React.AnchorHTMLAttributes<HTMLAnchorElement> & { to: string }) {
  return (
    <a
      href={to}
      onClick={(e) => {
        if (e.metaKey || e.ctrlKey || e.shiftKey) return;
        e.preventDefault();
        go(to);
      }}
      {...rest}
    >
      {children}
    </a>
  );
}

function MenuBar({ signedIn }: { signedIn: boolean }) {
  return (
    <nav className="menubar">
      <a className="brand" href="/"><img src="/logo.svg" alt="" /> myLinux</a>
      <a href="/docs">Docs</a>
      {signedIn && <Link to="/app">Your setup</Link>}
      <span className="spacer" />
      {signedIn ? <UserButton /> : <Link to="/sign-in">Sign in</Link>}
    </nav>
  );
}

export function NotConfigured() {
  return (
    <>
      <MenuBar signedIn={false} />
      <div className="centered">
        <div className="panel dialog">
          <h2>Sign-in is not switched on yet</h2>
          <p className="muted" style={{ marginTop: 12 }}>
            Accounts on mylinux.app use Clerk, and this server has no Clerk keys configured. Everything else
            works: <a href="/">the overview</a> and <a href="/docs">the docs</a>.
          </p>
        </div>
      </div>
    </>
  );
}

function Shell({ children }: { children: React.ReactNode }) {
  const path = usePath();
  const { user } = useUser();
  const tab = path.startsWith("/app/tokens") ? "tokens" : "machines";
  return (
    <>
      <MenuBar signedIn />
      <div className="appwrap">
        <h1>Your setup</h1>
        <p className="sub">
          {user?.firstName ? `${user.firstName}, ` : ""}one profile per machine, carried between Macs as mylinux.ini.
        </p>
        <div className="tabs">
          <Link to="/app" aria-current={tab === "machines" ? "page" : undefined}>Machines</Link>
          <Link to="/app/tokens" aria-current={tab === "tokens" ? "page" : undefined}>API tokens</Link>
        </div>
        {children}
      </div>
    </>
  );
}

export function App() {
  const path = usePath();

  if (path.startsWith("/sign-in") || path.startsWith("/sign-up")) {
    const Comp = path.startsWith("/sign-in") ? SignIn : SignUp;
    const base = path.startsWith("/sign-in") ? "/sign-in" : "/sign-up";
    return (
      <>
        <MenuBar signedIn={false} />
        <Show when="signed-out">
          <div className="centered">
            <Comp routing="path" path={base} />
          </div>
        </Show>
        <Show when="signed-in">
          <Redirect to="/app" />
        </Show>
      </>
    );
  }

  return (
    <>
      <Show when="signed-out">
        <Redirect to="/sign-in" />
      </Show>
      <Show when="signed-in">
        <Shell>
          {path.startsWith("/app/tokens") ? (
            <Tokens />
          ) : path.startsWith("/app/machines/") ? (
            <MachineEditor id={decodeURIComponent(path.slice("/app/machines/".length))} />
          ) : (
            <Machines />
          )}
        </Shell>
      </Show>
    </>
  );
}

function Redirect({ to }: { to: string }) {
  useEffect(() => { go(to); }, [to]);
  return null;
}
