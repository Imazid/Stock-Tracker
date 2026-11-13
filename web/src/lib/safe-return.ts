/** Accepts same-site paths for sign-in and confirmation redirects. */
export function safeReturnPath(value: string | null): string {
  if (!value?.startsWith("/") || value.startsWith("//") || /[\\\u0000-\u0020]/.test(value)) return "/";
  const origin = "https://stock-tracker.invalid";
  return new URL(value, origin).origin === origin ? value : "/";
}
