import { type Condition, type Operand, Op, Rule, StrategyValidator } from "../trading/strategy.ts";

interface DescribedRules {
  entry?: Condition;
  exit?: Condition;
  notes: string[];
  usedDefaultRSI: boolean;
}

/** A clause is accepted only when every comparison can run in the strategy engine. */
export function describedRules(text: string): DescribedRules | undefined {
  const hasTimedRule = /\b(?:rsi|relative strength index|ema|sma|(?:moving )?average|macd|bollinger|price|volume|close)\b/.test(text);
  const hasDirection = /\b(?:when|if|above|below|under|over|exceeds|crosses|once)\b|[<>≤≥]/.test(text);
  const onlyUndirectedCross = /\bcross(?:es|over)?\b/.test(text) &&
    !/\b(?:above|below|under|over|rsi|relative strength index)\b|[<>]/.test(text);
  if (!hasTimedRule || !hasDirection || onlyUndirectedCross) return undefined;

  const matches = [...text.matchAll(/\b(buy|sell|enter|exit)\b[^,;.!?\n]*?\b(?:when|if|once|on)\s+/g)];
  if (!matches.length) return undefined;
  const result: DescribedRules = { notes: [], usedDefaultRSI: false };
  const seen = new Set<string>();
  for (const [index, match] of matches.entries()) {
    const isBuy = match[1] === "buy" || match[1] === "enter";
    const key = isBuy ? "buy" : "sell";
    const fragment = text.slice(match.index + match[0].length, matches[index + 1]?.index);
    const clause = trimClause(fragment);
    const opposite = /^(?:the )?(?:opposite|reverse) cross(?:over)?$/.test(clause);
    const rule = seen.has(key) ? undefined : opposite && !isBuy ? reverseCross(result.entry) : readGroup(clause, result);
    seen.add(key);
    if (isBuy) result.entry = rule;
    else result.exit = rule ?? Rule.all([]);
    if (!rule) {
      const note = `Review the ${key} condition. The full comparison could not be read.`;
      if (!result.notes.includes(note)) result.notes.push(note);
    }
  }
  if (result.usedDefaultRSI) result.notes.push("Used 14 bars wherever the RSI period was omitted.");
  return result;
}

function trimClause(raw: string): string {
  const end = /(?:,\s*(?!\s*(?:and|or)\b)|[;\n!?]|\.(?!\d)|\b(?:with (?:a |an )?(?=\$)|with (?:a |an )?(?:stop loss|take profit)|(?:and )?ask me|for paper trading|in (?:a )?paper (?:portfolio|account)|every (?:hour|day|week|month|\d+\s*min)|once a day|hourly|daily|called|named)\b)/;
  return raw.split(end, 1)[0].replace(/,\s*(?=(?:and|or)\b)/g, " ").trim().replace(/\s+(?:and|then)$/, "");
}

function reverseCross(rule?: Condition): Condition | undefined {
  if (!rule?.left || !rule.right) return undefined;
  if (rule.op === "crossesAbove") return Rule.crossesBelow(rule.left, rule.right);
  if (rule.op === "crossesBelow") return Rule.crossesAbove(rule.left, rule.right);
}

function readGroup(text: string, result: DescribedRules): Condition | undefined {
  const groups = text.split(/\s+or\s+/);
  if (groups.length > 8) return undefined;
  const alternatives: Condition[] = [];
  for (const part of groups) {
    const comparisons = part.split(/\s+and\s+/);
    if (comparisons.length > 8) return undefined;
    const leaves: Condition[] = [];
    for (const comparison of comparisons) {
      const leaf = readComparison(comparison, result);
      if (!leaf) return undefined;
      leaves.push(leaf);
    }
    alternatives.push(leaves.length === 1 ? leaves[0] : Rule.all(leaves));
  }
  return alternatives.length === 1 ? alternatives[0] : Rule.any(alternatives);
}

function readComparison(raw: string, result: DescribedRules): Condition | undefined {
  const match = /\s*(\bcross(?:es)?\s+(?:back\s+)?(?:above|below|under|over)|\b(?:is\s+)?(?:above|below|under|over)|\b(?:drops?|falls?|goes|rises?|moves?|breaks?)\s+(?:above|below|under|over)|\bexceeds\b|[<>])\s*/.exec(raw);
  if (!match) return undefined;
  const left = readOperand(raw.slice(0, match.index), result);
  const right = readOperand(raw.slice(match.index + match[0].length), result);
  if (!left || !right || left.kind === "constant") return undefined;
  if (left.kind === "rsi" && right.kind === "constant" && right.value !== undefined && (right.value < 0 || right.value > 100)) return undefined;
  const relation = match[1];
  const above = relation === ">" || relation === "exceeds" || relation.endsWith("above") || relation.endsWith("over");
  if (relation.startsWith("cross")) return above ? Rule.crossesAbove(left, right) : Rule.crossesBelow(left, right);
  return above ? Rule.above(left, right) : Rule.below(left, right);
}

function readOperand(raw: string, result: DescribedRules): Operand | undefined {
  const text = raw.trim().replace(/^(?:(?:the|its)\s+)+/, "");
  if (/^[+-]?(?:\d+(?:\.\d*)?|\.\d+)$/.test(text) && Number.isFinite(Number(text))) return Op.constant(Number(text));
  if (["price", "close", "closing price"].includes(text)) return Op.close;
  if (text === "open" || text === "high" || text === "low") return Op.price(text);
  if (text === "volume") return Op.volume;
  const rsi = /^(?:rsi|relative strength index)(?:\s*\((\d+)\)|\s+(\d+))?$/.exec(text);
  if (rsi) {
    const periodText = rsi[1] ?? rsi[2];
    if (periodText === undefined) result.usedDefaultRSI = true;
    const period = Number(periodText ?? 14);
    return period >= 2 && period <= StrategyValidator.maxPeriod ? Op.rsi(period) : undefined;
  }
  const average = /^(\d+)[ -]?(?:day|hour|bar|period)s?\s+(ema|sma|(?:exponential |simple )?(?:moving )?average)$/.exec(text) ??
    /^(\d+)\s*(ema|sma)$/.exec(text);
  if (average) {
    const period = Number(average[1]), kind = average[2];
    if (period >= 2 && period <= StrategyValidator.maxPeriod) return kind === "ema" || kind.startsWith("exponential") ? Op.ema(period) : Op.sma(period);
  }
}
