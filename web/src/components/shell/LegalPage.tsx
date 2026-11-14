import Link from "next/link";
import type { ReactNode } from "react";

export function LegalPage({ title, children }: { title: string; children: ReactNode }) {
  return (
    <main className="mx-auto max-w-3xl px-5 py-10 sm:px-8 sm:py-16">
      <Link href="/" className="text-sm font-semibold text-text underline underline-offset-4">Stock Tracker</Link>
      <header className="mt-8 border-b border-border pb-5">
        <h1 className="text-3xl font-semibold tracking-tight sm:text-4xl">{title}</h1>
        <p className="mt-2 text-sm text-text-2">Updated <time dateTime="2026-11-14">14 November 2026</time></p>
      </header>
      <div className="space-y-7 pt-6 text-base leading-7 text-text-2 [&_a]:font-medium [&_a]:text-text [&_a]:underline [&_a]:underline-offset-4 [&_h2]:mb-2 [&_h2]:text-lg [&_h2]:font-semibold [&_h2]:text-text [&_p+p]:mt-3">
        {children}
      </div>
      <nav aria-label="Legal" className="mt-10 flex flex-wrap gap-x-5 gap-y-2 border-t border-border pt-5 text-sm">
        <Link href="/privacy" className="underline underline-offset-4">Privacy Policy</Link>
        <Link href="/terms" className="underline underline-offset-4">Terms of Service</Link>
      </nav>
    </main>
  );
}
