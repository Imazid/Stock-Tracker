"use client";

import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { type ReactNode, useState } from "react";
import { SessionProvider } from "@/lib/session";

export function Providers({ children }: { children: ReactNode }) {
  const [client] = useState(() => new QueryClient({
    defaultOptions: {
      queries: {
        staleTime: 15_000,
        retry: (count, error) => count < 1 && !(error instanceof Error && "status" in error && (error as { status: number }).status === 400),
        refetchOnWindowFocus: true,
      },
    },
  }));
  return (
    <QueryClientProvider client={client}>
      <SessionProvider>{children}</SessionProvider>
    </QueryClientProvider>
  );
}
