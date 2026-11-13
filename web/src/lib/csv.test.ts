import assert from "node:assert/strict";
import test from "node:test";
import { csvField } from "./csv.ts";

test("CSV escapes quotes and preserves quantities and empty values", () => {
  assert.equal(csvField('Apple, Inc. "common"'), '"Apple, Inc. ""common"""');
  assert.equal(csvField(0.00123), "0.00123");
  assert.equal(csvField(null), "");
});

test("spreadsheet formulas in text fields export as literal text", () => {
  assert.equal(csvField("  =1+1"), "\"'  =1+1\"");
  assert.equal(csvField("@TICKER"), "\"'@TICKER\"");
  assert.equal(csvField(-1), "-1");
});
