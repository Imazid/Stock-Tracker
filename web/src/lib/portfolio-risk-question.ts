export const PORTFOLIO_RISK_QUESTION = "What are the biggest risks in my current holdings?";

export function portfolioRiskQuestion(text: string): boolean {
  const question = text.toLowerCase().trim().replace(/^please\s+/, "").replace(/[?.!]+$/, "");
  return /^(?:what are the (?:biggest|main|top) risks in my (?:current )?(?:holdings|portfolio)|(?:show|review|summari[sz]e) my portfolio (?:risk|concentration)|how concentrated is my portfolio)$/.test(question);
}
