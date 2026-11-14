// Boundaries of the provider order path, checked on the source itself:
//  * only the adapters (_shared/brokers) know a provider's address;
//  * only _shared/oms/execute.ts can call submit / replace / cancel on an adapter;
//  * nothing on the practice path (trading-api, agent-scheduler, _shared/server, _shared/trading,
//    _shared/market, _shared/studio) imports the provider path;
//  * no model is called anywhere on the provider path, and no key is written into code.
// Run: npx -y deno test --allow-read supabase/functions/tests/oms_boundaries.test.ts

import { assert, assertEquals } from "jsr:@std/assert@1";

async function sources(dir: URL, out: { path: string; text: string }[] = []): Promise<{ path: string; text: string }[]> {
  for await (const entry of Deno.readDir(dir)) {
    const url = new URL(entry.name + (entry.isDirectory ? "/" : ""), dir);
    if (entry.isDirectory) {
      if (entry.name !== "tests") await sources(url, out);
    } else if (entry.name.endsWith(".ts")) {
      out.push({ path: url.pathname.split("/supabase/functions/")[1], text: await Deno.readTextFile(url) });
    }
  }
  return out;
}
const code = (text: string) => text.replace(/\/\*[\s\S]*?\*\//g, "").split("\n").map((l) => l.replace(/^\s*\/\/.*$/, "").replace(/\s\/\/ .*$/, "")).join("\n");
const PROVIDER = /^(broker-orders|broker-connections|provider-maintenance|_shared\/(brokers|oms|vault))\//;

Deno.test("provider path: addresses, money-moving calls, imports, models, keys", async () => {
  const files = await sources(new URL("../", import.meta.url));
  const provider = files.filter((f) => PROVIDER.test(f.path));
  const practice = files.filter((f) => !PROVIDER.test(f.path));
  assert(provider.length >= 15 && practice.length >= 20, `found ${provider.length} provider / ${practice.length} practice files`);

  // Provider hosts appear only in the adapters.
  for (const f of files) {
    for (const host of code(f.text).matchAll(/(?:https?|wss?):\/\/([a-zA-Z0-9.-]+)/g)) {
      if (/alpaca\.markets$|coinbase\.com$/.test(host[1]) && host[1] !== "data.alpaca.markets") {
        assert(f.path.startsWith("_shared/brokers/"), `${f.path} names ${host[1]}`);
      }
    }
  }

  // Only execute.ts sends, replaces or cancels through an adapter.
  const movers = provider.filter((f) => /\.(submit|replace|cancel)\(\s*(ctx|actx|this|adapterContext)/.test(code(f.text)) && !f.path.startsWith("_shared/brokers/")).map((f) => f.path);
  assertEquals(movers, ["_shared/oms/execute.ts"]);
  const workers = files.filter((file) => file.path.startsWith("provider-maintenance/"));
  assert(workers.some((worker) => worker.path === "provider-maintenance/worker.ts"));
  for (const worker of workers) {
    assert(!/\b(submitIntent|cancelIntent|replaceIntent)\b/.test(code(worker.text)), "the worker only reads provider state");
  }

  // The practice path never imports the provider path.
  for (const f of practice) {
    assert(!/from\s+["'][^"']*(_shared\/)?(brokers|oms|vault)\//.test(f.text), `${f.path} imports the provider path`);
  }

  // No model, no keys in code, credentials env read in one place.
  for (const f of provider) {
    const text = code(f.text);
    for (const pattern of [/openai/i, /anthropic/i, /generativelanguage/i, /\bgemini\b/i, /\/v1\/(chat\/completions|messages|responses)\b/i]) {
      assert(!pattern.test(text), `${f.path} mentions ${pattern}`);
    }
    assert(!/eyJ[A-Za-z0-9_-]{20,}|sb_secret_|sk_live_|PK[A-Z0-9]{18}|BEGIN EC PRIVATE KEY-----\n[A-Za-z0-9+/]{20}/.test(f.text), `${f.path} contains something key-shaped`);
    if (/BROKER_CREDENTIALS_KEKS/.test(text)) assertEquals(f.path, "_shared/vault/envelope.ts");
  }

  // The practice server's live seam still has no implementation.
  const implementers = files.filter((f) => /implements\s+LiveBrokerAdapter|:\s*LiveBrokerAdapter\s*=\s*\{/.test(code(f.text))).map((f) => f.path);
  assertEquals(implementers, []);
});
