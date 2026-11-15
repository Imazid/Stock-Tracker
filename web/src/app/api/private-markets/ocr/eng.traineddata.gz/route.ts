import { readFile } from "node:fs/promises";
import path from "node:path";

export const dynamic = "force-static";

export async function GET() {
  const bytes = await readFile(path.join(process.cwd(), "node_modules/@tesseract.js-data/eng/4.0.0_best_int/eng.traineddata.gz"));
  return new Response(new Uint8Array(bytes), {
    headers: {
      "Content-Type": "application/octet-stream",
      "Cache-Control": "public, max-age=86400",
    },
  });
}
