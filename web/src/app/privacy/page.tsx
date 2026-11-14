import type { Metadata } from "next";
import { LegalPage } from "@/components/shell/LegalPage";

export const metadata: Metadata = { title: "Privacy Policy" };

export default function PrivacyPage() {
  const email = process.env.STOCK_TRACKER_PRIVACY_EMAIL?.trim();
  const privacyEmail = email && /^[a-z0-9._+-]+@[a-z0-9.-]+\.[a-z]{2,}$/i.test(email) ? email : undefined;

  return (
    <LegalPage title="Privacy Policy">
      <section>
        <h2>Account, device and portfolio data</h2>
        <p>Stock Tracker is intended for people aged 13 and older. Stock Tracker uses your email address and account ID to sign you in and associate your saved records with your account. On the web, session cookies keep you signed in and browser storage saves preferences. The iPhone app stores settings and portfolio records on your device. Selected listed-market records can sync when you sign in. When you connect a broker, SnapTrade supplies the holdings, activity and account information you authorise.</p>
        <p>Manual private holdings, valuations, cash flows and imported AngelList statements are stored on your iPhone. The AngelList connection uses the permissions you grant directly to AngelList and stores its token in Keychain. Signed-in Private Markets features store selected company IDs, monitoring preferences, research history, reports, and reviewed excerpts you save. Approved investment providers can also report your jurisdiction, investor classification, eligibility outcome, application and investment records. The provider handles identity documents and funds.</p>
      </section>
      <section>
        <h2>Research and AI</h2>
        <p>An AI research or assistant request sends your question and relevant context to the model service. Depending on the feature and your choices, this can include market data, public filings or a summary of your listed portfolio. On the iPhone, you can turn portfolio sharing on or off under Privacy &amp; data. In Private Markets, you choose your source material. Stock Tracker extracts text from PDF or text files on your device, saves only reviewed excerpts with your permission, and requires separate permission to send a private excerpt to an approved model service. If you enable daily Private Markets summaries, the model receives selected published company information.</p>
      </section>
      <section>
        <h2>Service providers and processing locations</h2>
        <p>Supabase hosts the Stock Tracker account database in Australia. Vercel hosts the web workspace. Market data and currency services receive the symbols, query text or currency codes needed to answer a request. AI services include Google Gemini, OpenAI and, for some web features, Anthropic. Apple handles subscriptions, optional speech recognition and push delivery. Technology, market-data, brokerage, AI and advertising providers may process relevant information outside Australia, including in the United States.</p>
        <p>On the iPhone, you choose which alerts and summaries to enable. When available and enabled, remote Private Markets notifications use a device token stored encrypted by Stock Tracker. You can change notifications, microphone permissions and tracking in iPhone Settings. Face ID is optional and Stock Tracker receives the authentication result.</p>
      </section>
      <section>
        <h2>Ads and tracking</h2>
        <p>When ads are enabled on the iPhone Free plan, Google AdMob can use device identifiers, approximate location, ad interactions and diagnostics for delivery and measurement. Tracking requires your permission, which you can change under Privacy &amp; Security, then Tracking, in iPhone Settings.</p>
      </section>
      <section>
        <h2>Retention and your choices</h2>
        <p>Stock Tracker keeps active account records so you can use the features you enable. On the iPhone, open Account to export Private Markets records or delete your account. The Portfolio tab also offers exports for selected listed records. You can export Private Markets records from My Private Portfolio, including device records and, if you choose, cloud records. Account deletion removes active Stock Tracker account records and clears this account’s app data from the iPhone used to delete it. Exported copies, Apple subscriptions and records held by an external broker or investment provider are managed separately.</p>
      </section>
      <section>
        <h2>Access, correction and complaints</h2>
        <p>You can ask for access to your personal information, request a correction or accessible copy of this policy, or raise a privacy complaint. {privacyEmail ? <>Email <a href={`mailto:${privacyEmail}`}>{privacyEmail}</a>.</> : "Use App Support on the Stock Tracker App Store listing."} Tell us how to reach you and describe your request. We may verify your identity before disclosing or changing account data. We will review what happened and respond to you.</p>
        <p>In Australia, if you’re dissatisfied with our response, you can contact the <a href="https://www.oaic.gov.au/privacy/privacy-complaints">Office of the Australian Information Commissioner</a>.</p>
      </section>
    </LegalPage>
  );
}
