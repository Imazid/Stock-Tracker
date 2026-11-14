import type { Metadata } from "next";
import { LegalPage } from "@/components/shell/LegalPage";

export const metadata: Metadata = { title: "Terms of Service" };

export default function TermsPage() {
  return (
    <LegalPage title="Terms of Service">
      <section>
        <h2>Using Stock Tracker</h2>
        <p>These terms apply when you use Stock Tracker. The service provides market data, watchlists, portfolios, alerts, research and practice-trading tools. Keep your account credentials secure and enter information you have permission to use. You can close your Stock Tracker account in the iPhone app.</p>
      </section>
      <section>
        <h2>Market data and research</h2>
        <p>Prices, alerts, valuations and research can be delayed, incomplete or inaccurate. AI outputs can contain errors. Research and calculators provide general information and do not provide personal financial advice. Review original sources, current offer documents and your own circumstances before making an investment decision. A private investment may be difficult to value or sell.</p>
      </section>
      <section>
        <h2>Practice trading and investment providers</h2>
        <p>Practice trades use simulated funds. Connecting a broker can import authorised position and activity records. Separately, an eligible private offer may link to an approved, licensed investment provider. The provider runs its own application, identity, eligibility, payment, withdrawal and settlement process under its terms. Stock Tracker displays ownership only after receiving provider confirmation.</p>
        <p>When you use Private Markets research, only save excerpts that you have permission to store. Obtain permission to share them with an AI provider before choosing that option.</p>
      </section>
      <section>
        <h2>Subscriptions and consumer rights</h2>
        <p>Apple bills optional iPhone subscriptions. You can manage renewal or cancel in Apple subscription settings. Deleting your Stock Tracker account does not cancel an Apple subscription. Your rights and remedies under applicable law, including the Australian Consumer Law, continue to apply.</p>
      </section>
    </LegalPage>
  );
}
