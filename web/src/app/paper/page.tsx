import type { Metadata } from "next";
import { PaperView } from "./paper-view";

export const metadata: Metadata = { title: "Paper Trading" };

export default function PaperPage() {
  return <PaperView />;
}
