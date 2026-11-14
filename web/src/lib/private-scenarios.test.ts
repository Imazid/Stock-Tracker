import assert from "node:assert/strict";
import test from "node:test";
import { dilutedOwnership, exitProceeds, pricedRoundOwnership, scenarioAmount, type Preference } from "./private-scenarios.ts";

test("scenario inputs accept decimal values and correctly grouped thousands", () => {
  assert.equal(scenarioAmount(" 5,000.25 "), 5000.25);
  assert.equal(scenarioAmount(".5"), 0.5);
  assert.equal(scenarioAmount("0"), 0);
  for (const value of ["", "0x50", "50e8", "1,0000", "1,00.50", "-1", "Infinity"]) {
    assert.equal(scenarioAmount(value), null);
  }
});

test("priced round and dilution use the stated post-money values", () => {
  assert.equal(pricedRoundOwnership(5_000, 1_000_000), 0.005);
  assert.equal(dilutedOwnership(0.02, 500_000, 2_000_000), 0.015);
  assert.equal(dilutedOwnership(0.25, 0, 2_000_000), 0.25);
  assert.equal(dilutedOwnership(0.25, 1_000_000, 1_000_000), null);
  assert.equal(pricedRoundOwnership(1, 0), null);
  assert.equal(pricedRoundOwnership(1000, 999), null);
});

test("the preference waterfall covers shortfall, conversion, and uncapped participation", () => {
  const preferred: Preference = { shareClass: "preferred", preferredShare: 0.2, totalPreference: 1000, participating: false };
  const common: Preference = { ...preferred, shareClass: "common" };
  assert.equal(exitProceeds(500, 0.1, common), 0);
  assert.equal(exitProceeds(500, 0.1, preferred), 250);
  assert.equal(exitProceeds(3000, 0.1, preferred), 500);
  assert.equal(exitProceeds(3000, 0.1, common), 250);
  assert.equal(exitProceeds(10000, 0.1, preferred), 1000);
  assert.equal(exitProceeds(10000, 0.1, { ...preferred, participating: true }), 1400);
  assert.equal(exitProceeds(10000, 0.3, preferred), null);
  assert.equal(exitProceeds(10000, 0.85, common), null);
  assert.equal(exitProceeds(-1, 0.1, preferred), null);
  assert.equal(exitProceeds(1000, 0.005), 5);
  for (const equityValue of [0, 500, 3000, 5000, 10000]) {
    for (const participating of [false, true]) {
      const proceeds = [exitProceeds(equityValue, 0.8, { ...common, participating }),
        exitProceeds(equityValue, 0.2, { ...preferred, participating })];
      assert.equal(proceeds.reduce<number>((total, amount) => total + (amount ?? NaN), 0), equityValue);
    }
  }
});
