export type ShareClass = "common" | "preferred";

export type Preference = {
  shareClass: ShareClass;
  preferredShare: number;
  totalPreference: number;
  participating: boolean;
};

const maximumAmount = Number.MAX_SAFE_INTEGER / 100;

function validAmount(amount: number) {
  return Number.isFinite(amount) && amount >= 0 && amount <= maximumAmount;
}

export function scenarioAmount(input: string): number | null {
  const value = input.trim();
  if (!/^(?:(?:\d+|\d{1,3}(?:,\d{3})+)(?:\.\d+)?|\.\d+)$/.test(value)) return null;
  const amount = Number(value.replaceAll(",", ""));
  return validAmount(amount) ? amount : null;
}

export function pricedRoundOwnership(investment: number, postMoney: number): number | null {
  if (!validAmount(investment) || !validAmount(postMoney) || investment <= 0 || investment > postMoney) return null;
  return investment / postMoney;
}

export function dilutedOwnership(ownership: number, newCapital: number, postMoney: number): number | null {
  if (!(ownership >= 0 && ownership <= 1) || !validAmount(newCapital) || !validAmount(postMoney) || newCapital >= postMoney) return null;
  return ownership * ((postMoney - newCapital) / postMoney);
}

export function exitProceeds(equityValue: number, ownership: number, preference?: Preference): number | null {
  if (!validAmount(equityValue) || !(ownership >= 0 && ownership <= 1)) return null;
  if (!preference) return equityValue * ownership;

  const { shareClass, preferredShare, totalPreference, participating } = preference;
  if (!(preferredShare > 0 && preferredShare < 1) || !validAmount(totalPreference)) return null;
  const classShare = shareClass === "preferred" ? preferredShare : 1 - preferredShare;
  if (ownership - classShare > Number.EPSILON) return null;

  const preferencePaid = Math.min(totalPreference, equityValue);
  const preferredPayout = participating
    ? preferencePaid + (equityValue - preferencePaid) * preferredShare
    : Math.max(preferencePaid, equityValue * preferredShare);
  const classPayout = shareClass === "preferred" ? preferredPayout : equityValue - preferredPayout;
  return Math.min(1, ownership / classShare) * classPayout;
}
