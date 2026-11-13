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
  { href: "/portfolio", label: "Portfolio", icon: Wallet },
  { href: "/watchlists", label: "Watchlists", icon: ListChecks },
  { href: "/ai", label: "AI Workspace", icon: BrainCircuit },
  { href: "/agents", label: "Agent Studio", icon: Bot },
  { href: "/strategies", label: "Strategies", icon: FlaskConical },
  { href: "/paper", label: "Paper Trading", icon: Workflow },
  { href: "/orders", label: "Orders", icon: ClipboardList },
  { href: "/activity", label: "Activity", icon: Activity },
  { href: "/connections", label: "Connections", icon: Cable },
  { href: "/settings", label: "Settings", icon: Settings },
];

export function isActive(pathname: string, href: string): boolean {
  if (href === "/") return pathname === "/";
  return pathname === href || pathname.startsWith(`${href}/`);
}
