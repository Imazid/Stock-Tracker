import { createHmac } from "node:crypto";

function currentCode(secret) {
  const alphabet = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567";
  const bits = [...secret.toUpperCase().replaceAll("=", "")].map((char) => alphabet.indexOf(char).toString(2).padStart(5, "0")).join("");
  const key = Buffer.from(bits.match(/.{8}/g).map((octet) => Number.parseInt(octet, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(Date.now() / 30_000)));
  const digest = createHmac("sha1", key).update(counter).digest();
  return String((digest.readUInt32BE(digest[19] & 15) & 0x7fffffff) % 1_000_000).padStart(6, "0");
}

export async function freshAuthenticatorCode(secret) {
  const elapsed = Date.now() % 30_000;
  if (elapsed > 25_000) {
    await new Promise((resolve) => setTimeout(resolve, 30_500 - elapsed));
  }
  return currentCode(secret);
}
