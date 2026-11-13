"use client";

import type { Session, User } from "@supabase/supabase-js";
import { createContext, type ReactNode, useContext, useEffect, useMemo, useState } from "react";
import { supabaseConfigured } from "@/lib/env";
import { browserSupabase } from "@/lib/supabase/client";

export type SessionState =
  | { status: "unconfigured" }
  | { status: "loading" }
  | { status: "signedOut" }
  | { status: "signedIn"; user: User; session: Session };

const SessionContext = createContext<SessionState>({ status: "loading" });

export function SessionProvider({ children }: { children: ReactNode }) {
  const [state, setState] = useState<SessionState>(supabaseConfigured ? { status: "loading" } : { status: "unconfigured" });

  useEffect(() => {
    const supabase = browserSupabase();
    if (!supabase) return;
    let active = true;
    supabase.auth.getSession().then(({ data }) => {
      if (!active) return;
      setState(data.session ? { status: "signedIn", user: data.session.user, session: data.session } : { status: "signedOut" });
    }).catch(() => active && setState({ status: "signedOut" }));
    const { data } = supabase.auth.onAuthStateChange((_event, session) => {
      setState(session ? { status: "signedIn", user: session.user, session } : { status: "signedOut" });
    });
    return () => {
      active = false;
      data.subscription.unsubscribe();
    };
  }, []);

  const value = useMemo(() => state, [state]);
  return <SessionContext.Provider value={value}>{children}</SessionContext.Provider>;
}

export function useSession(): SessionState {
  return useContext(SessionContext);
}

/** A fresh access token for calling edge functions, or undefined when signed out. */
export async function accessToken(): Promise<string | undefined> {
  const supabase = browserSupabase();
  if (!supabase) return undefined;
  const { data } = await supabase.auth.getSession();
  return data.session?.access_token;
}
