import { createWorker, OEM } from "tesseract.js";

export async function createScanReader(signal: AbortSignal) {
  // Serve the language data under the filename expected by the OCR worker.
  const langPath = new URL("/api/private-markets/ocr", window.location.origin);
  signal.throwIfAborted();
  const failed = Promise.withResolvers<never>();
  const loading = createWorker("eng", OEM.LSTM_ONLY, {
    workerPath: new URL("tesseract.js/dist/worker.min.js", import.meta.url).href,
    corePath: new URL("tesseract.js-core/tesseract-core-lstm.wasm.js", import.meta.url).href,
    langPath: langPath.href,
    workerBlobURL: false,
    cacheMethod: "none",
    errorHandler: () => failed.reject(new Error("The English scan reader is unavailable.")),
  }).then(async (worker) => {
    if (signal.aborted) {
      await worker.terminate();
      signal.throwIfAborted();
    }
    return worker;
  });
  return Promise.race([loading, failed.promise]);
}
