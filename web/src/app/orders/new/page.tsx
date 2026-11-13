import type { Metadata } from "next";
import { Suspense } from "react";
import { TicketView } from "./ticket-view";

export const metadata: Metadata = { title: "New order" };

export default function NewOrderPage() {
  return <Suspense><TicketView /></Suspense>;
}
