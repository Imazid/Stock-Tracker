import type { Metadata, Viewport } from "next";
import { AppShell } from "@/components/shell/AppShell";
import { Providers } from "@/components/shell/Providers";
import { THEME_SCRIPT } from "@/components/shell/theme";
import "./globals.css";

export const metadata: Metadata = {
  title: { default: "Stock Tracker", template: "%s · Stock Tracker" },
  description: "Markets, watchlists, strategies and order review for stocks and crypto.",
};

export const viewport: Viewport = {
  themeColor: [{ media: "(prefers-color-scheme: dark)", color: "#0a0b0d" }, { media: "(prefers-color-scheme: light)", color: "#f6f7f9" }],
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en-AU" data-theme="dark" suppressHydrationWarning>
      <head>
        {/* Sets the theme before first paint so there's no flash. */}
        <script dangerouslySetInnerHTML={{ __html: THEME_SCRIPT }} />
      </head>
      <body className="min-h-dvh antialiased">
        <Providers>
          <AppShell>{children}</AppShell>
        </Providers>
      </body>
    </html>
  );
}
