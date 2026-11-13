import type { Metadata } from "next";
import { IntentView } from "./intent-view";

export const metadata: Metadata = { title: "Order" };

export default async function IntentPage({ params }: { params: Promise<{ id: string }> }) {
  return <IntentView id={(await params).id} />;
}
