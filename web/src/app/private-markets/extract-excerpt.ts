import type { Worker as ScanWorker } from "tesseract.js";

const maxBytes = 10 * 1024 * 1024;
export const maxExcerptLength = 4_500;

function excerptPrefix(value: string, limit: number): string {
  return value.slice(0, limit).replace(/[\uD800-\uDBFF]$/, "");
}

async function readPDF(data: Uint8Array, signal: AbortSignal, onScan: () => void) {
  const { AnnotationMode, getDocument, PasswordException, PDFWorker } = await import("pdfjs-dist");
  signal.throwIfAborted();
  const port = new Worker(new URL("pdfjs-dist/build/pdf.worker.mjs", import.meta.url), { type: "module" });
  const worker = PDFWorker.create({ port });
  const task = getDocument({
    data, worker, disableFontFace: true, disableWorkerRendering: true,
    useWorkerFetch: false, useWasm: false, enableXfa: false,
    maxImageSize: 24_000_000, canvasMaxAreaInBytes: 96_000_000,
  });
  const interrupted = Promise.withResolvers<never>();
  const stop = () => interrupted.reject(signal.reason);
  const workerFailed = () => interrupted.reject(new Error("The PDF reader could not start."));
  signal.addEventListener("abort", stop, { once: true });
  port.addEventListener("error", workerFailed, { once: true });
  let extracted = false;
  let recognizer: ScanWorker | undefined;
  let scanFailed = false;
  try {
    const pdf = await Promise.race([task.promise, interrupted.promise]);
    const pages = Math.min(pdf.numPages, 50);
    let text = "";
    let limited = pdf.numPages > pages;
    let scans = 0;
    let usedOCR = false;
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
      let streamFinished = false;
      try {
        while (value.length < remaining) {
          const { done, value: chunk } = await Promise.race([reader.read(), interrupted.promise]);
          if (done) {
            streamFinished = true;
            break;
          }
          for (const item of chunk.items) {
            if (!("str" in item)) continue;
            const part = item.str + (item.hasEOL ? "\n" : " ");
            value += part.slice(0, remaining - value.length);
            if (value.length >= remaining) break;
          }
        }
      } finally {
        if (!streamFinished) await Promise.race([reader.cancel(), interrupted.promise]).catch(() => {});
      }
      if (!value.trim()) {
        if (scanFailed) continue;
        if (scans >= 8) {
          limited = true;
        } else {
          scans++;
          const canvas = document.createElement("canvas");
          try {
            const native = page.getViewport({ scale: 1 });
            const scale = Math.min(3, 2_200 / Math.max(native.width, native.height));
            const viewport = page.getViewport({ scale });
            canvas.width = Math.max(1, Math.ceil(viewport.width));
            canvas.height = Math.max(1, Math.ceil(viewport.height));
            const rendering = page.render({ canvas, viewport, annotationMode: AnnotationMode.DISABLE });
            const cancel = () => rendering.cancel();
            signal.addEventListener("abort", cancel, { once: true });
            try {
              await Promise.race([rendering.promise, interrupted.promise]);
            } finally {
              signal.removeEventListener("abort", cancel);
            }
            const context = canvas.getContext("2d", { willReadFrequently: true });
            const pixels = context?.getImageData(0, 0, canvas.width, canvas.height).data;
            const hasMarks = pixels?.some((channel, index) => index % 4 !== 3 && channel < 235);
            if (hasMarks) {
              onScan();
              if (!recognizer) {
                const { createScanReader } = await Promise.race([import("./scan-excerpt"), interrupted.promise]);
                recognizer = await Promise.race([createScanReader(signal), interrupted.promise]);
              }
              const { data } = await Promise.race([recognizer.recognize(canvas), interrupted.promise]);
              value = data.text.trim().slice(0, remaining);
              usedOCR ||= Boolean(value);
            }
          } catch {
            signal.throwIfAborted();
            scanFailed = true;
            limited = true;
          } finally {
            canvas.width = canvas.height = 0;
          }
        }
      }
      if (value.trim()) text += heading + value.trim();
      if (value.length >= remaining) {
        limited = true;
        break;
      }
    }
    if (!text && scanFailed) throw new Error("Could not read the scanned pages. Try reopening the PDF or paste an excerpt.");
    extracted = true;
    return { text, limited, usedOCR };
  } catch (error) {
    if (error instanceof PasswordException) {
      throw new Error("Unlock the PDF before importing it.");
    }
    throw error;
  } finally {
    if (recognizer) await recognizer.terminate().catch(() => {});
    const cleanup = task.destroy().catch(() => {});
    if (extracted) await Promise.race([cleanup, interrupted.promise]).catch(() => {});
    signal.removeEventListener("abort", stop);
    port.removeEventListener("error", workerFailed);
    worker.destroy();
    port.terminate();
  }
}

export async function extractExcerpt(file: File, signal: AbortSignal, onScan: () => void) {
  if (!file.size || file.size > maxBytes) throw new Error("Choose a non-empty file up to 10 MB.");
  const extension = file.name.split(".").pop()?.toLowerCase();
  if (extension !== "pdf" && extension !== "txt") throw new Error("Choose a PDF or UTF-8 text file.");

  const bytes = new Uint8Array(await file.arrayBuffer());
  signal.throwIfAborted();
  let text: string;
  let limited = false;
  let usedOCR = false;
  if (extension === "pdf") {
    ({ text, limited, usedOCR } = await readPDF(bytes, signal, onScan));
    if (!text) throw new Error("This PDF has no readable text. Try a clearer scan or paste an excerpt.");
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
    usedOCR,
  };
}
