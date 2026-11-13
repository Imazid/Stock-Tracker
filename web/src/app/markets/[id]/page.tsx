import type { Metadata } from "next";
import { InstrumentView } from "./instrument-view";

export async function generateMetadata({ params }: { params: Promise<{ id: string }> }): Promise<Metadata> {
  const id = decodeURIComponent((await params).id);
  return { title: id.split(":")[1] ?? id };
}

export default async function InstrumentPage({ params }: { params: Promise<{ id: string }> }) {
  return <InstrumentView id={decodeURIComponent((await params).id)} />;
}
