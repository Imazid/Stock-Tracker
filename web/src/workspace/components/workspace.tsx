"use client";

import Link from "next/link";
import { useCallback, useEffect, useRef, useState } from "react";
import type { User } from "@supabase/supabase-js";
import {
  Activity, ArrowRight, ExternalLink, Bell, Bot, ChartCandlestick, ChevronDown, Command, FlaskConical, KeyRound,
  LayoutGrid, LogIn, LogOut, Menu, Radio, Search, Settings2, Sparkles, Star, Wallet, X,
} from "lucide-react";
import { backend, service } from "../lib/backend";
import { readJournal } from "../lib/journal";
import { emptyJournal, fromHolding, fromWatch, instrumentID, message, popular, storedExchange, storedKind, storedTicker, type Holding, type Instrument } from "../lib/models";
import Auth from "./auth";
import { Market } from "./market";
import Palette from "./palette";
import { JournalForm, PersonalList, Portfolio } from "./portfolio";
import { Connections, Research } from "./research";
import { Agents, OrderTicket, PaperDesk, StrategyStudio, type TradeAction, type TradingState } from "./trading";
import { Brand, Empty, Modal } from "./ui";

const sections = [
  { id: "overview", title: "Overview", icon: LayoutGrid, description: "Follow markets and track your investments in one workspace." },
  { id: "markets", title: "Markets", icon: ChartCandlestick, description: "Explore price history across stocks, ETFs and crypto." },
  { id: "portfolio", title: "Portfolio", icon: Wallet, description: "Track holdings, allocation and transaction history from your Stock Tracker account." },
  { id: "watchlist", title: "Watchlist", icon: Star, description: "Manage the assets and price alerts you follow on Stock Tracker." },
  { id: "paper", title: "Paper trading", icon: Activity, description: "Practise orders with virtual cash and market prices." },
  { id: "agents", title: "Agents", icon: Bot, description: "Run paper agents, review proposals and inspect their activity." },
  { id: "strategy", title: "Strategy Studio", icon: FlaskConical, description: "Describe a strategy and test its rules against market history." },
  { id: "research", title: "Research", icon: Sparkles, description: "Review price history, filings and company sources." },
  { id: "settings", title: "Account", icon: Settings2, description: "Manage your account session and read-only brokerage connections." },
] as const;

type Page = typeof sections[number]["id"];
type Dialog = "login"|"mfa"|"command"|"holdingFinder"|"holding"|"alert"|"order"|null;

function initialPage(): Page {
  if (typeof window === "undefined") return "overview";
  return sections.find(section => section.id === window.location.hash.slice(1))?.id ?? "overview";
}

export default function Workspace({ aiEnabled, brokerageEnabled }: { aiEnabled: boolean; brokerageEnabled: boolean }) {
  const [page,setPage] = useState<Page>("overview");
  const [asset,setAsset] = useState<Instrument>(popular[0]);
  const [collapsed,setCollapsed] = useState(false);
  const [mobile,setMobile] = useState(false);
  const [user,setUser] = useState<User | null>(null);
  const [ready,setReady] = useState(!backend);
  const [verified,setVerified] = useState(false);
  const [dialog,setDialog] = useState<Dialog>(null);
  const [journal,setJournal] = useState(emptyJournal);
  const [journalError,setJournalError] = useState("");
  const [trading,setTrading] = useState<TradingState>();
  const [tradingError,setTradingError] = useState("");
  const [notice,setNotice] = useState<{text:string;error?:boolean}>();
  const [holding,setHolding] = useState<Holding>();
  const [holdingAsset,setHoldingAsset] = useState<Instrument>(popular[0]);
  const [refresh,setRefresh] = useState(0);
  const [syncing,setSyncing] = useState(false);

  const sessionCheck = useRef(0);
  const privateOwner = useRef<string | undefined>(undefined);
  const validateSession = useCallback(async () => {
    const attempt = ++sessionCheck.current;
    if (!backend) return;
    const {data} = await backend.auth.getUser();
    const level = data.user ? await backend.auth.mfa.getAuthenticatorAssuranceLevel() : null;
    if (attempt !== sessionCheck.current) return;
    if (privateOwner.current !== data.user?.id) {
      privateOwner.current = data.user?.id;
      setJournal(emptyJournal); setTrading(undefined); setJournalError(""); setTradingError("");
    }
    setUser(data.user);
    if (data.user && level) {
      if (level.error) {
        setVerified(false); setNotice({ text: "Unable to verify the account session. Sign in again.", error: true });
      } else {
        const needsMfa = level.data.currentLevel !== "aal2" && level.data.nextLevel === "aal2";
        setVerified(!needsMfa);
        if (needsMfa) setDialog("mfa");
      }
    } else {
      setVerified(false); setJournal(emptyJournal); setTrading(undefined); setJournalError(""); setTradingError("");
    }
    setReady(true);
  }, []);

  useEffect(() => {
    const hash = () => setPage(initialPage());
    hash();
    window.addEventListener("hashchange",hash);
    const {data} = backend?.auth.onAuthStateChange(event => {
      if (["INITIAL_SESSION","SIGNED_IN","SIGNED_OUT","MFA_CHALLENGE_VERIFIED"].includes(event)) void setTimeout(() => void validateSession(), 0);
    }) ?? {};
    return () => { window.removeEventListener("hashchange",hash); data?.subscription.unsubscribe(); };
  }, [validateSession]);

  const signedIn = Boolean(user && verified);
  const userID = signedIn ? user?.id : undefined;

  useEffect(() => {
    if (!userID) return;
    let alive = true;
    const reload = async () => {
      setSyncing(true);
      const [journal,trades] = await Promise.allSettled([readJournal(userID),service<{ state: TradingState }>("trading",{action:"state"})]);
      if (!alive) return;
      if (journal.status === "fulfilled") { setJournal(journal.value); setJournalError(""); } else setJournalError(message(journal.reason));
      if (trades.status === "fulfilled") { setTrading(trades.value.state); setTradingError(""); } else setTradingError(message(trades.reason));
      setSyncing(false);
    };
    void reload();
    return () => { alive = false; };
  }, [userID,refresh]);

  useEffect(() => {
    if (!userID) return;
    const reload = () => { if (!document.hidden) setRefresh(count => count + 1); };
    const timer = setInterval(reload,90_000);
    document.addEventListener("visibilitychange",reload);
    return () => { clearInterval(timer); document.removeEventListener("visibilitychange",reload); };
  }, [userID]);

  useEffect(() => {
    const key = (event: KeyboardEvent) => {
      if ((event.metaKey || event.ctrlKey) && event.key.toLowerCase() === "k") {
        event.preventDefault(); setDialog(value => value === "command" ? null : value === "mfa" ? value : "command");
      }
    };
    window.addEventListener("keydown",key);
    return () => window.removeEventListener("keydown",key);
  }, []);

  useEffect(() => {
    if (!notice) return;
    const timer = setTimeout(() => setNotice(undefined),7500);
    return () => clearTimeout(timer);
  },[notice]);

  function navigate(next: Page) {
    setPage(next); setMobile(false);
    if (window.location.hash !== `#${next}`) window.history.pushState(null,"",`#${next}`);
    window.scrollTo({top:0});
  }

  function selectAsset(item: Instrument, destination: Page = "markets") { setAsset(item); setDialog(null); navigate(destination); }
  function signIn() { setDialog(user && !verified ? "mfa" : "login"); }
  function showOrder() {
    if (!signedIn) { signIn(); return; }
    setDialog("order");
  }
  function saved(text: string) { setNotice({text}); setDialog(null); setRefresh(count => count + 1); }

  async function toggleWatch(item: Instrument) {
    if (!backend || !userID) { signIn(); return; }
    const row = journal.watch.find(row => instrumentID(fromWatch(row)) === instrumentID(item));
    const result = row ? await backend.from("watchlist_assets").update({deleted_at:new Date().toISOString()}).eq("user_id",userID).eq("id",row.id).select("id").single() :
      await backend.from("watchlist_assets").upsert({user_id:userID,symbol:storedTicker(item),name:item.name,kind:storedKind(item),exchange:storedExchange(item),deleted_at:null},{onConflict:"user_id,symbol"});
    if (result.error) setNotice({text:message(result.error),error:true});
    else saved(row ? `${item.symbol} removed from watchlist.` : `${item.symbol} added to watchlist.`);
  }

  async function alertChange(id: string, patch: Record<string, unknown>) {
    if (!backend || !userID) return;
    const {error} = await backend.from("price_alerts").update(patch).eq("user_id",userID).eq("id",id).select("id").single();
    if (error) setNotice({text:message(error),error:true});
    else saved(patch.deleted_at ? "Alert removed." : "Alert updated.");
  }

  const tradeAction: TradeAction = async (action,fields,key) => {
    try {
      const result = await service<Record<string,unknown> & {state?:TradingState}>("trading",{...fields,action,includeState:true},key);
      if (result.state) setTrading(result.state); else setRefresh(count => count + 1);
      if (result.accepted === false && action === "approveProposal") setNotice({text:String(result.summary ?? "The proposal was declined by the risk engine."),error:true});
      else if (action !== "placeOrder") setNotice({text:"Trading workspace updated."});
      return result;
    } catch (error) { setNotice({text:message(error),error:true}); throw error; }
  };

  const current = sections.find(section => section.id === page)!;
  const marketPage = page === "overview" || page === "markets";
  const nav = (start: number,end: number) => sections.slice(start,end).map(section => {
    const Icon = section.icon;
    return <button key={section.id} title={collapsed ? section.title : undefined} className={page === section.id ? "active" : ""} aria-current={page === section.id ? "page" : undefined} onClick={() => navigate(section.id)}><Icon size={18}/><span>{section.title}</span></button>;
  });
  const requiresTrading = page === "paper" || page === "agents";

  return <div className={`workspace ${collapsed ? "folded" : ""}`}>
    {mobile && <button className="nav-scrim" aria-label="Close navigation" onClick={() => setMobile(false)}/>}
    <aside className={`sidebar ${mobile ? "mobile-open" : ""}`}>
      <a className="brand-link" href="#overview" aria-label="Stock Tracker overview" onClick={event => {event.preventDefault(); navigate("overview");}}><Brand small={collapsed}/></a>
      <button className="workspace-switch" onClick={() => setDialog("command")}><span className="workspace-symbol"><Activity size={16}/></span><span>Trading workspace<small>Quick navigation</small></span><ChevronDown className="switch-chevron" size={14}/></button>
      <nav aria-label="Workspace">
        <div className="nav-group"><p>WORKSPACE</p>{nav(0,4)}</div>
        <div className="nav-group"><p>TOOLS</p>{nav(4,8)}</div>
        <div className="nav-group settings-nav"><p>SETTINGS</p>{nav(8,9)}</div>
      </nav>
      <div className="sidebar-bottom"><span className="avatar">{signedIn ? (user?.email?.slice(0,2).toUpperCase() || "ST") : <KeyRound size={15}/>}</span><span><strong>{signedIn ? user?.email : "Stock Tracker account"}</strong><small>{signedIn ? "Account connected" : "Sync with your iOS app"}</small></span><button className="icon-button" aria-label={signedIn ? "Open account" : "Sign in"} onClick={() => signedIn ? navigate("settings") : signIn()}>{signedIn ? <Settings2 size={16}/> : <LogIn size={16}/>}</button></div>
    </aside>

    <div className="body-shell">
      <header className="topbar">
        <div className="crumb"><button className="icon-button side-toggle" aria-label={collapsed ? "Expand sidebar" : "Collapse sidebar"} onClick={() => setCollapsed(value => !value)}><Menu size={19}/></button><button className="icon-button mobile-toggle" aria-label="Open navigation" onClick={() => setMobile(true)}><Menu size={20}/></button><span>Workspace</span><span className="crumb-slash">/</span><strong>{current.title}</strong></div>
        <div className="top-actions"><button className="search-trigger" aria-label="Search assets and commands" onClick={() => setDialog("command")}><Search size={16}/><span>Search anything</span><kbd><Command size={12}/> K</kbd></button><button className="icon-button top-bell" aria-label="Price alerts" onClick={() => navigate("watchlist")}><Bell size={18}/></button>
          {signedIn ? <button className="button secondary small" disabled={syncing} onClick={() => setRefresh(count => count + 1)}>{syncing ? "Syncing…" : "Sync"}</button> : <button className="button primary small sign-button" onClick={signIn}>Sign in <ArrowRight size={15}/></button>}
        </div>
      </header>
      <main id="main" className="main">
        <header className="page-heading"><div><div className="market-label"><span className="status-dot"/>{marketPage ? "MARKET WORKSPACE" : "STOCK TRACKER"}</div><h1>{page === "overview" ? "Market overview" : current.title}</h1><p>{current.description}</p></div>
          {marketPage && <button aria-label="Find an asset" className="button secondary market-search" onClick={() => setDialog("command")}><Search size={16}/> Find an asset <ArrowRight size={15}/></button>}
          {(page === "strategy" || page === "research") && signedIn && <button className="button secondary" onClick={() => setDialog("command")}><Search size={16}/> Change asset</button>}
        </header>

        {marketPage && <Market key={page} asset={asset} onAsset={setAsset} signedIn={signedIn} watch={journal.watch} onWatch={item => void toggleWatch(item)} onTrade={showOrder} onSignIn={signIn} full={page === "markets"}/>}
        {page === "overview" && <div className="overview-bottom"><div className="overview-callout"><span className="callout-icon"><Wallet size={19}/></span><div><h2>Your investment workspace</h2><p>{signedIn ? `${journal.holdings.length} holdings · ${journal.watch.length} saved assets` : "Open your portfolios, watchlist and paper trades with your Stock Tracker account."}</p></div><button className="button secondary small" onClick={() => signedIn ? navigate("portfolio") : signIn()}>{signedIn ? "View portfolio" : "Connect account"}<ArrowRight size={15}/></button></div><span className="data-note"><Radio size={14}/> Market quotes may be delayed. Check the source timestamp.</span></div>}
        {!marketPage && page !== "settings" && !signedIn && <section className="panel"><Empty icon={<KeyRound size={22}/>} title={ready ? "Sign in to open this workspace" : "Checking your account…"} text={ready ? "Use the same Stock Tracker account you use on iOS." : undefined}>{ready && <button className="button primary" onClick={signIn}>Sign in <ArrowRight size={15}/></button>}</Empty></section>}
        {signedIn && (journalError && ["portfolio","watchlist"].includes(page)) && <p role="alert" className="notice error">{journalError}</p>}
        {signedIn && page === "portfolio" && <>
          <Portfolio journal={journal} onAsset={selectAsset} onAdd={() => { setHolding(undefined); setDialog("holdingFinder"); }} onEdit={row => { setHolding(row); setHoldingAsset(fromHolding(row)); setDialog("holding"); }}/>
          <div className="data-note"><Link className="text-button" href="/portfolio">Portfolio performance and CSV export <ExternalLink size={13}/></Link></div>
        </>}
        {signedIn && page === "watchlist" && <PersonalList journal={journal} onAsset={selectAsset} onWatch={item => void toggleWatch(item)} onAlert={() => setDialog("alert")} onAlertChange={(id,patch) => void alertChange(id,patch)}/>}
        {signedIn && requiresTrading && !trading && <section className="panel"><Empty icon={<Activity size={20}/>} title={tradingError || "Loading your trading workspace…"}>{tradingError && <button className="button secondary" onClick={() => setRefresh(count => count + 1)}>Retry</button>}</Empty></section>}
        {signedIn && page === "paper" && trading && <PaperDesk state={trading} act={tradeAction} onNewOrder={showOrder} onAsset={selectAsset}/>}
        {signedIn && page === "agents" && trading && <><Agents state={trading} act={tradeAction}/><div className="data-note"><Link className="text-button" href="/activity">Open full activity history <ExternalLink size={13}/></Link></div></>}
        {signedIn && page === "strategy" && <><StrategyStudio key={instrumentID(asset)} asset={asset} act={tradeAction}/><div className="data-note"><Link className="text-button" href="/strategies">Open the advanced strategy editor <ExternalLink size={13}/></Link></div></>}
        {signedIn && page === "research" && <Research key={instrumentID(asset)} asset={asset} journal={journal} enabled={aiEnabled}/>}
        {page === "settings" && <><section className="panel table-panel"><div className="panel-heading"><h2><Settings2 size={18}/> Stock Tracker account</h2></div>
          <div className="list-row"><span><strong>{signedIn ? user?.email : "Signed out"}</strong><small>{signedIn ? "Synced with Stock Tracker" : "Your account is required to access synced data."}</small></span>{signedIn ?
            <button className="button secondary" onClick={async () => {const result = await backend?.auth.signOut({scope:"local"}); if (result?.error) setNotice({text:message(result.error),error:true}); else {++sessionCheck.current; privateOwner.current = undefined; setUser(null); setVerified(false); setJournal(emptyJournal); setTrading(undefined); setDialog(null);} }}><LogOut size={16}/> Sign out</button> :
            <button className="button primary" onClick={signIn}>Sign in</button>}</div>
        </section>{signedIn && <><Connections enabled={brokerageEnabled}/><div className="data-note"><Link className="text-button" href="/connections">Provider account settings <ExternalLink size={13}/></Link></div></>}</>}
      </main>
    </div>

    {dialog && <Modal title={{login:"Sign in to Stock Tracker",mfa:"Verify your account",command:"Search workspace",holdingFinder:"Choose a holding",holding:holding ? "Edit holding" : "Add holding",alert:"Create price alert",order:"Paper order ticket"}[dialog]} onClose={() => setDialog(null)} palette={dialog === "command" || dialog === "holdingFinder"}>
      {(dialog === "login" || dialog === "mfa") && <Auth key={dialog} mode={dialog} onDone={async () => {setDialog(null); await validateSession();}}/>}
      {(dialog === "command" || dialog === "holdingFinder") && <Palette connected={signedIn} initial={dialog === "holdingFinder" ? asset.symbol : ""}
        commands={dialog === "holdingFinder" ? [] : sections.map(section => {const Icon = section.icon; return {label:section.title,icon:<Icon size={17}/>,action:() => {navigate(section.id); setDialog(null);}};})}
        choose={item => { if (dialog === "holdingFinder") {setHoldingAsset(item); setDialog("holding");} else if (page === "strategy" || page === "research") selectAsset(item,page); else selectAsset(item); }}
        custom={item => { if (dialog === "holdingFinder") {setHoldingAsset(item); setDialog("holding");} else if (page === "strategy" || page === "research") selectAsset(item,page); else selectAsset(item); }}/>}
      {dialog === "holding" && userID && <JournalForm kind="holding" asset={holdingAsset} holding={holding} userID={userID} onDone={saved}/>}
      {dialog === "alert" && userID && <JournalForm kind="alert" asset={asset} userID={userID} onDone={saved}/>}
      {dialog === "order" && signedIn && <OrderTicket key={trading?.ledgers.map(ledger => ledger.id).join(",") ?? "loading"} state={trading} asset={asset} act={tradeAction} onDone={saved}/>}
    </Modal>}
    {notice && <div className={`toast ${notice.error ? "error" : ""}`} role={notice.error ? "alert" : "status"}><span>{notice.text}</span><button aria-label="Dismiss message" className="icon-button" onClick={() => setNotice(undefined)}><X size={16}/></button></div>}
  </div>;
}
