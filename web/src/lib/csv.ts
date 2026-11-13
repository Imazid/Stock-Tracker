export function csvField(value: string | number | null): string {
  if (value === null) return "";
  if (typeof value === "number") return String(value);
  const spreadsheetText = /^[\u0000-\u0020]*[=+\-@]|^[\t\r\n]/.test(value) ? "'" + value : value;
  return '"' + spreadsheetText.replaceAll('"', '""') + '"';
}
