const maxBytes = 10 * 1024 * 1024;
export const maxExcerptLength = 4_500;

function excerptPrefix(value: string, limit: number): string {
  return value.slice(0, limit).replace(/[\uD800-\uDBFF]$/, "");
}

async function readPDF(data: Uint8Array, signal: AbortSignal) {
  const { getDocument, PasswordException, PDFWorker } = await import("pdfjs-dist");
  signal.throwIfAborted();
  const port = new Worker(new URL("pdfjs-dist/build/pdf.worker.mjs", import.meta.url), { type: "module" });
  const worker = PDFWorker.create({ port });
  const task = getDocument({
    data, worker, disableFontFace: true, disableWorkerRendering: true,
    useWorkerFetch: false, useWasm: false, enableXfa: false,
  });
  const interrupted = Promise.withResolvers<never>();
  const stop = () => interrupted.reject(signal.reason);
  const workerFailed = () => interrupted.reject(new Error("The PDF reader could not start."));
  signal.addEventListener("abort", stop, { once: true });
  port.addEventListener("error", workerFailed, { once: true });
  let extracted = false;
  try {
    const pdf = await Promise.race([task.promise, interrupted.promise]);
    const pages = Math.min(pdf.numPages, 50);
    let text = "";
    let limited = pdf.numPages > pages;
    for (let number = 1; number <= pages; number++) {
      signal.throwIfAborted();
      const heading = `${text ? "\n\n" : ""}[Page ${number}]\n`;
      const remaining = maxExcerptLength + 1 - text.length - heading.length;
      if (remaining <= 0) {
        limited = true;
        break;
      }
      const page = await Promise.race([pdf.getPage(number), interrupted.promise]);
      const reader = page.streamTextContent().getReader();
      let value = "";
      try {
        while (value.length < remaining) {
          const { done, value: chunk } = await Promise.race([reader.read(), interrupted.promise]);
          if (done) break;
          for (const item of chunk.items) {
            if (!("str" in item)) continue;
            const part = item.str + (item.hasEOL ? "\n" : " ");
            value += part.slice(0, remaining - value.length);
            if (value.length >= remaining) break;
          }
        }
      } finally {
        void reader.cancel().catch(() => {});
      }
      if (value.trim()) text += heading + value.trim();
      if (value.length >= remaining) {
        limited = true;
        break;
      }
    }
    extracted = true;
    return { text, limited };
  } catch (error) {
    if (error instanceof PasswordException) {
      throw new Error("Unlock the PDF before importing it.");
    }
    throw error;
  } finally {
    const cleanup = task.destroy().catch(() => {});
    if (extracted) await Promise.race([cleanup, interrupted.promise]).catch(() => {});
    signal.removeEventListener("abort", stop);
    port.removeEventListener("error", workerFailed);
    worker.destroy();
    port.terminate();
  }
}

export async function extractExcerpt(file: File, signal: AbortSignal) {
  if (!file.size || file.size > maxBytes) throw new Error("Choose a non-empty file up to 10 MB.");
  const extension = file.name.split(".").pop()?.toLowerCase();
  if (extension !== "pdf" && extension !== "txt") throw new Error("Choose a PDF or UTF-8 text file.");

  const bytes = new Uint8Array(await file.arrayBuffer());
  signal.throwIfAborted();
  let text: string;
  let limited = false;
  if (extension === "pdf") {
    ({ text, limited } = await readPDF(bytes, signal));
    if (!text) throw new Error("This PDF has no selectable text. Use Deal Room on iPhone to read scanned pages.");
  } else {
    try {
      text = new TextDecoder("utf-8", { fatal: true }).decode(bytes).trim();
    } catch {
      throw new Error("Save the text file as UTF-8 and try again.");
    }
    if (text.includes("\u0000")) throw new Error("Choose a readable UTF-8 text file.");
    if (!text) throw new Error("The text file is empty.");
  }
  signal.throwIfAborted();
  return {
    title: excerptPrefix(file.name.replace(/\.[^.]+$/, "").trim(), 160),
    text: excerptPrefix(text, maxExcerptLength).trimEnd(),
    limited: limited || text.length > maxExcerptLength,
  };
}
