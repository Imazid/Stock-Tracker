import { assert, assertEquals } from "jsr:@std/assert@1";
import { ApnsSender, validDeviceToken } from "../_shared/private-markets/apns.ts";
import { fromBase64, fromUtf8, toBase64, utf8 } from "../_shared/secure/encoding.ts";

Deno.test("private push signs a valid ES256 Apple request and sends only generic copy", async () => {
  const { publicKey, privateKey } = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", privateKey));
  const requests: Request[] = [];
  const transport: typeof fetch = (input, init) => {
    requests.push(new Request(input, init));
    return Promise.resolve(new Response(null, { status: 200 }));
  };
  const sender = new ApnsSender({
    environment: "sandbox", team: "TEAM123456", keyId: "KEY1234567", privateKey: toBase64(der),
  }, transport);
  const token = "8f".repeat(32);
  const lease = crypto.randomUUID();
  const now = 1_790_000_000_000;
  assertEquals(await sender.send(token, lease, now), "accepted");
  assertEquals(await sender.send(token, crypto.randomUUID(), now + 60_000), "accepted");
  const [initial, followUp] = requests;
  assertEquals(initial.url, "https://api.sandbox.push.apple.com/3/device/" + token);
  assertEquals(initial.headers.get("authorization"), followUp.headers.get("authorization"));
  assertEquals(initial.headers.get("apns-topic"), "Cubeplay.Stock-Tracker");
  assertEquals(initial.headers.get("apns-id"), lease);
  assertEquals(initial.headers.get("apns-expiration"), "0");
  const authorization = initial.headers.get("authorization") ?? "";
  const [header, payload, signature] = authorization.slice("bearer ".length).split(".");
  assertEquals(JSON.parse(fromUtf8(fromBase64(header))), { alg: "ES256", kid: "KEY1234567" });
  assertEquals(JSON.parse(fromUtf8(fromBase64(payload))), { iss: "TEAM123456", iat: now / 1_000 });
  assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, publicKey, fromBase64(signature), utf8(header + "." + payload)));
  assertEquals(await initial.json(), {
    aps: { alert: { title: "Private Markets update", body: "Open Stock Tracker to see what’s new." }, sound: "default" },
    privateMarkets: true,
  });
  await sender.send(token, crypto.randomUUID(), now + 51 * 60_000);
  assert(authorization !== requests[2].headers.get("authorization"));
});

Deno.test("private push separates permanent token failures from retryable APNs failures", async () => {
  const pair = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const statuses = [410, 400, 503];
  const sender = new ApnsSender({
    environment: "production", team: "TEAM123456", keyId: "KEY1234567",
    privateKey: toBase64(new Uint8Array(await crypto.subtle.exportKey("pkcs8", pair.privateKey))),
  }, (input) => {
    assert(String(input).startsWith("https://api.push.apple.com/3/device/"));
    const status = statuses.shift();
    return Promise.resolve(Response.json({ reason: status === 400 ? "BadDeviceToken" : "None" }, { status }));
  });
  assertEquals(validDeviceToken("aa".repeat(16)), true);
  assertEquals(await sender.send("../wrong", crypto.randomUUID()), "invalid");
  assertEquals(await sender.send("aa".repeat(32), crypto.randomUUID()), "invalid");
  assertEquals(await sender.send("aa".repeat(32), crypto.randomUUID()), "invalid");
  assertEquals(await sender.send("aa".repeat(32), crypto.randomUUID()), "retry");
});
