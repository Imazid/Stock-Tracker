import {
  Activity, Bot, BrainCircuit, Cable, ClipboardList, FlaskConical, LayoutDashboard, LineChart, ListChecks, Settings, Wallet, Workflow,
  type LucideIcon,
} from "lucide-react";

export interface NavItem {
  href: string;
  label: string;
  icon: LucideIcon;
  /** Not built in this pass: listed so the shape of the product is visible, but disabled. */
  soon?: string;
}

export const NAV: NavItem[] = [
  { href: "/", label: "Overview", icon: LayoutDashboard },
  { href: "/markets", label: "Markets", icon: LineChart },
  { href: "/portfolio", label: "Portfolio", icon: Wallet, soon: "Synced holdings and performance aren't in the web app yet." },
  { href: "/watchlists", label: "Watchlists", icon: ListChecks },
  { href: "/ai", label: "AI Workspace", icon: BrainCircuit, soon: "The research assistant isn't in the web app yet." },
  { href: "/agents", label: "Agent Studio", icon: Bot, soon: "Agents run in the iPhone app today; the web studio isn't built yet." },
  { href: "/strategies", label: "Strategies", icon: FlaskConical },
  { href: "/paper", label: "Paper Trading", icon: Workflow, soon: "Practice trading runs in the iPhone app; the web version waits for the trading API." },
  { href: "/orders", label: "Orders", icon: ClipboardList },
  { href: "/activity", label: "Activity", icon: Activity, soon: "The audit timeline isn't in the web app yet." },
  { href: "/connections", label: "Connections", icon: Cable },
  { href: "/settings", label: "Settings", icon: Settings },
];

export function isActive(pathname: string, href: string): boolean {
  if (href === "/") return pathname === "/";
  return pathname === href || pathname.startsWith(`${href}/`);
}
