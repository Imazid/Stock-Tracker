import type { Metadata } from "next";
import Link from "next/link";
import { Suspense } from "react";
import { LoginView } from "./login-view";

export const metadata: Metadata = { title: "Sign in" };

export default function LoginPage() {
  return (
    <>
      <Suspense><LoginView /></Suspense>
      <nav aria-label="Legal" className="mt-6 flex justify-center gap-5 text-sm text-text-2">
        <Link href="/privacy" className="underline underline-offset-4">Privacy Policy</Link>
        <Link href="/terms" className="underline underline-offset-4">Terms of Service</Link>
      </nav>
    </>
  );
}
