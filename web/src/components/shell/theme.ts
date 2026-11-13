export type ThemeChoice = "dark" | "light" | "system";
export const THEME_KEY = "st-theme";

/** Runs before first paint (inlined in <head>) so the page never flashes the wrong theme. */
export const THEME_SCRIPT = `(function(){try{var t=localStorage.getItem("${THEME_KEY}");var d=t==="light"?"light":t==="system"?(window.matchMedia("(prefers-color-scheme: light)").matches?"light":"dark"):"dark";document.documentElement.dataset.theme=d}catch(e){document.documentElement.dataset.theme="dark"}})();`;

export function readTheme(): ThemeChoice {
  try {
    const t = localStorage.getItem(THEME_KEY);
    return t === "light" || t === "system" ? t : "dark";
  } catch {
    return "dark";
  }
}

export function applyTheme(choice: ThemeChoice): void {
  try {
    localStorage.setItem(THEME_KEY, choice);
  } catch {
    // Private mode / blocked storage: the choice just won't persist.
  }
  const resolved = choice === "system" ? (window.matchMedia("(prefers-color-scheme: light)").matches ? "light" : "dark") : choice;
  document.documentElement.dataset.theme = resolved;
  window.dispatchEvent(new CustomEvent("st-theme-change", { detail: resolved }));
}
