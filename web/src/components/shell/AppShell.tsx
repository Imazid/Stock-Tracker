"use client";

import Link from "next/link";
import { usePathname, useRouter } from "next/navigation";
import { BrainCircuit, ChevronsLeft, ChevronsRight, LogIn, LogOut, Menu, Moon, Search, Sun, X } from "lucide-react";
import { type ReactNode, useCallback, useEffect, useState } from "react";
import { Button } from "@/components/ui/Button";
import { cn } from "@/lib/cn";
import { useSession } from "@/lib/session";
import { browserSupabase } from "@/lib/supabase/client";
import { AssistantPanel } from "./AssistantPanel";
import { CommandPalette } from "./CommandPalette";
import { EnvironmentBadge } from "./EnvironmentBadge";
import { isActive, NAV } from "./nav";
import { applyTheme } from "./theme";

const COLLAPSE_KEY = "st-sidebar-collapsed";

function useStoredFlag(key: string): [boolean, (v: boolean) => void] {
  const [value, setValue] = useState(false);
  useEffect(() => {
    try {
      // Reading browser storage after hydration (it isn't available on the server).
      // eslint-disable-next-line react-hooks/set-state-in-effect
      setValue(localStorage.getItem(key) === "1");
    } catch {
      // ignore
    }
  }, [key]);
  const set = useCallback((v: boolean) => {
    setValue(v);
    try {
      localStorage.setItem(key, v ? "1" : "0");
    } catch {
      // ignore
    }
  }, [key]);
  return [value, set];
}

function useResolvedTheme(): "dark" | "light" {
  const [theme, setTheme] = useState<"dark" | "light">("dark");
  useEffect(() => {
    const read = () => setTheme(document.documentElement.dataset.theme === "light" ? "light" : "dark");
    read();
    window.addEventListener("st-theme-change", read);
    return () => window.removeEventListener("st-theme-change", read);
  }, []);
  return theme;
}

function Sidebar({ collapsed, onNavigate }: { collapsed: boolean; onNavigate?: () => void }) {
  const pathname = usePathname();
  return (
    <nav aria-label="Main" className="flex flex-col gap-0.5 p-2">
      {NAV.map((item) => {
        const Icon = item.icon;
        const active = isActive(pathname, item.href);
        if (item.soon) {
          return (
            <span key={item.href} aria-disabled="true" title={item.soon}
              className={cn("flex h-9 cursor-not-allowed items-center gap-3 rounded-lg px-2.5 text-[13px] text-text-3", collapsed && "justify-center px-0")}>
              <Icon aria-hidden className="h-4 w-4 shrink-0 opacity-60" />
              {!collapsed ? (<><span className="flex-1 truncate">{item.label}</span><span className="rounded border border-border px-1 text-[10px] uppercase tracking-wide">Soon</span></>) : <span className="sr-only">{item.label} (coming soon)</span>}
            </span>
          );
        }
        return (
          <Link key={item.href} href={item.href} onClick={onNavigate} aria-current={active ? "page" : undefined} title={collapsed ? item.label : undefined}
            className={cn("flex h-9 items-center gap-3 rounded-lg px-2.5 text-[13px] font-medium transition-colors",
              active ? "bg-primary-soft text-text" : "text-text-2 hover:bg-surface-2 hover:text-text",
              collapsed && "justify-center px-0")}>
            <Icon aria-hidden className={cn("h-4 w-4 shrink-0", active && "text-primary-fg")} />
            {!collapsed ? <span className="truncate">{item.label}</span> : <span className="sr-only">{item.label}</span>}
          </Link>
        );
      })}
    </nav>
  );
}

function Brand({ collapsed }: { collapsed: boolean }) {
  return (
    <Link href="/" className={cn("flex h-14 items-center gap-2 px-4 font-semibold tracking-tight", collapsed && "justify-center px-0")}>
      <span aria-hidden className="flex h-7 w-7 items-center justify-center rounded-lg bg-primary text-[13px] font-bold text-primary-text">ST</span>
      {!collapsed ? <span className="text-[15px]">Stock Tracker</span> : <span className="sr-only">Stock Tracker</span>}
    </Link>
  );
}

function Account() {
  const session = useSession();
  const router = useRouter();
  if (session.status === "unconfigured") {
    return <span className="hidden text-xs text-text-3 md:inline" title="Set NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_ANON_KEY">Accounts not configured</span>;
  }
  if (session.status === "loading") return <span className="skeleton h-8 w-20" aria-hidden />;
  if (session.status === "signedOut") {
    return <Link href="/login" className="inline-flex h-8 items-center gap-1.5 rounded-lg bg-primary px-3 text-[13px] font-medium text-primary-text hover:bg-primary-hover"><LogIn aria-hidden className="h-3.5 w-3.5" />Sign in</Link>;
  }
  return (
    <div className="flex items-center gap-2">
      <span className="hidden max-w-[160px] truncate text-xs text-text-2 md:inline" title={session.user.email ?? undefined}>{session.user.email}</span>
      <Button size="sm" variant="ghost" aria-label="Sign out" title="Sign out"
        onClick={async () => { await browserSupabase()?.auth.signOut(); router.refresh(); }}>
        <LogOut className="h-4 w-4" />
      </Button>
    </div>
  );
}

export function AppShell({ children }: { children: ReactNode }) {
  const pathname = usePathname();
  return pathname === "/" ? children : <ToolsShell>{children}</ToolsShell>;
}

function ToolsShell({ children }: { children: ReactNode }) {
  const [collapsed, setCollapsed] = useStoredFlag(COLLAPSE_KEY);
  const [mobileOpen, setMobileOpen] = useState(false);
  const [paletteOpen, setPaletteOpen] = useState(false);
  const [assistantOpen, setAssistantOpen] = useState(false);
  const theme = useResolvedTheme();

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if ((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "k") {
        e.preventDefault();
        setPaletteOpen((o) => !o);
      }
      if (e.key === "/" && !(e.target instanceof HTMLInputElement || e.target instanceof HTMLTextAreaElement || e.target instanceof HTMLSelectElement)) {
        e.preventDefault();
        setPaletteOpen(true);
      }
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);

  return (
    <div className="flex min-h-dvh">
      <a href="#main" className="sr-only focus:not-sr-only focus:fixed focus:left-2 focus:top-2 focus:z-50 focus:rounded-lg focus:bg-surface focus:px-3 focus:py-2">Skip to content</a>
      {/* Desktop sidebar */}
      <aside className={cn("sticky top-0 hidden h-dvh shrink-0 flex-col border-r border-border bg-surface lg:flex", collapsed ? "w-16" : "w-60")}>
        <Brand collapsed={collapsed} />
        <div className="flex-1 overflow-y-auto"><Sidebar collapsed={collapsed} /></div>
        <div className="border-t border-border p-2">
          <Button variant="ghost" size="sm" className="w-full" onClick={() => setCollapsed(!collapsed)} aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"}>
            {collapsed ? <ChevronsRight className="h-4 w-4" /> : <><ChevronsLeft className="h-4 w-4" /><span>Collapse</span></>}
          </Button>
        </div>
      </aside>

      {/* Mobile drawer */}
      {mobileOpen ? (
        <div className="fixed inset-0 z-40 lg:hidden">
          <div className="absolute inset-0 bg-black/50" onClick={() => setMobileOpen(false)} aria-hidden />
          <aside className="relative flex h-full w-72 flex-col border-r border-border bg-surface">
            <div className="flex items-center justify-between pr-2"><Brand collapsed={false} />
              <Button variant="ghost" size="sm" onClick={() => setMobileOpen(false)} aria-label="Close menu"><X className="h-4 w-4" /></Button></div>
            <div className="flex-1 overflow-y-auto"><Sidebar collapsed={false} onNavigate={() => setMobileOpen(false)} /></div>
          </aside>
        </div>
      ) : null}

      <div className="flex min-w-0 flex-1 flex-col">
        {/* Practice strip: a thin amber line along the very top, on every page. */}
        <div aria-hidden className="h-0.5 w-full bg-warn" />
        <header className="sticky top-0 z-30 flex h-14 items-center gap-2 border-b border-border bg-bg/85 px-3 backdrop-blur md:px-5">
          <Button variant="ghost" size="sm" className="lg:hidden" onClick={() => setMobileOpen(true)} aria-label="Open menu"><Menu className="h-4 w-4" /></Button>
          <button type="button" onClick={() => setPaletteOpen(true)}
            className="flex h-9 min-w-0 flex-1 items-center gap-2 rounded-lg border border-border bg-surface px-3 text-left text-[13px] text-text-3 hover:border-border-strong md:max-w-md">
            <Search aria-hidden className="h-4 w-4 shrink-0" />
            <span className="truncate">Search markets…</span>
            <kbd className="ml-auto hidden rounded border border-border px-1.5 text-[10px] md:inline">⌘K</kbd>
          </button>
          <div className="ml-auto flex items-center gap-1.5 md:gap-2">
            <EnvironmentBadge />
            <Button variant="ghost" size="sm" aria-label={theme === "dark" ? "Switch to light mode" : "Switch to dark mode"} title="Theme"
              onClick={() => applyTheme(theme === "dark" ? "light" : "dark")}>
              {theme === "dark" ? <Sun className="h-4 w-4" /> : <Moon className="h-4 w-4" />}
            </Button>
            <Button variant={assistantOpen ? "secondary" : "ghost"} size="sm" aria-pressed={assistantOpen} aria-label="Assistant panel" title="Assistant"
              onClick={() => setAssistantOpen((o) => !o)}>
              <BrainCircuit className="h-4 w-4" />
            </Button>
            <Account />
          </div>
        </header>
        <div className="flex min-h-0 flex-1">
          <main id="main" className="min-w-0 flex-1 px-4 py-5 md:px-6 md:py-6">{children}</main>
          <AssistantPanel open={assistantOpen} onClose={() => setAssistantOpen(false)} />
        </div>
      </div>
      <CommandPalette open={paletteOpen} onClose={() => setPaletteOpen(false)} />
    </div>
  );
}
