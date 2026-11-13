import path from "node:path";
import type { NextConfig } from "next";

// The trading engine, OMS contract and provider types live outside this app, in
// ../supabase/functions/_shared (shared with the Supabase edge functions and mirrored by the
// Swift TradingCore). Turbopack only resolves files under its root, so the root is the
// repository, not web/. Those files use Deno-style explicit `.ts` import extensions, which
// Turbopack resolves as-is.
const repoRoot = path.join(__dirname, "..");

const nextConfig: NextConfig = {
  // Cache Components / Partial Prefetching are off on purpose: every page here reads
  // per-request data (session cookies, live quotes) and nothing should be prerendered with
  // a price baked into it.
  turbopack: {
    root: repoRoot,
    rules: {
      "*.css": {
        loaders: ["@tailwindcss/turbopack"],
        as: "*.css",
      },
    },
  },
  outputFileTracingRoot: repoRoot,
  poweredByHeader: false,
  devIndicators: false,
  async headers() {
    return [
      {
        source: "/:path*",
        headers: [
          { key: "X-Content-Type-Options", value: "nosniff" },
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          { key: "X-Frame-Options", value: "DENY" },
          { key: "Permissions-Policy", value: "camera=(), microphone=(), geolocation=()" },
        ],
      },
    ];
  },
};

export default nextConfig;
