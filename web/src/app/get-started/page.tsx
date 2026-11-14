import type { Metadata } from "next";
import { GetStartedView } from "./get-started-view";

export const metadata: Metadata = { title: "Get started" };

export default function GetStartedPage() {
  return <GetStartedView brokerageEnabled={process.env.ENABLE_SNAPTRADE === "true"}
    aiEnabled={process.env.ENABLE_AI === "true"} />;
}
