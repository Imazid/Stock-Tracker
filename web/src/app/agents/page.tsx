import type { Metadata } from "next";
import { AgentsView } from "./agents-view";

export const metadata: Metadata = { title: "Agent Studio" };

export default function AgentsPage() {
  return <AgentsView />;
}
