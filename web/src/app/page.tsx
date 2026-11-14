import type { Metadata } from "next";
import Workspace from "@/workspace/components/workspace";
import { fmpConfigured } from "@/server/research/licensed";
import "@fontsource-variable/inter";
import "@fontsource-variable/space-grotesk";
import "@/workspace/styles.css";

export const metadata: Metadata = {
  title: "Market Overview",
  icons: { icon: "/tracker.svg" },
};

export default function OverviewPage() {
  return <Workspace aiEnabled={process.env.ENABLE_AI === "true"} brokerageEnabled={process.env.ENABLE_SNAPTRADE === "true"} logosEnabled={fmpConfigured()} />;
}
