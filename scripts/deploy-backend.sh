#!/usr/bin/env bash
# Deploys the Stock Tracker backend (schema + Edge Functions) to Stock Tracker's OWN
# Supabase project. It refuses known Miraa project refs and asks you to type the target
# ref before changing anything.
#
#   scripts/deploy-backend.sh                 # project opruuwczvrwklmwdtsaw
#   STOCK_TRACKER_PROJECT_REF=<ref> scripts/deploy-backend.sh
#
# Secrets never appear on screen: the DB password and the credential KEK are read from
# the macOS Keychain. Provider keys (SnapTrade, Gemini, OpenAI) are set by you afterwards.
set -euo pipefail
cd "$(dirname "$0")/.."

REF="${STOCK_TRACKER_PROJECT_REF:-opruuwczvrwklmwdtsaw}"
DB_PASSWORD_ITEM="supabase-stock-tracker-db"
KEK_ITEM="stock-tracker-credential-kek"

case "$REF" in
  yrczfezcexyowtjoiwhw|egegfokohnmzfgqnrzwi)
    echo "Refusing: $REF is a Miraa project. Stock Tracker has its own project." >&2
    exit 1 ;;
esac

echo "This deploys the Stock Tracker backend to Supabase project: $REF"
read -r -p "Type the project ref to continue: " typed
[ "$typed" = "$REF" ] || { echo "Cancelled."; exit 1; }

DB_PASSWORD="$(security find-generic-password -s "$DB_PASSWORD_ITEM" -w)"

echo "1/5  Linking…"
supabase link --project-ref "$REF" --password "$DB_PASSWORD" >/dev/null

echo "2/5  Migrations that would be applied:"
supabase db push --dry-run --password "$DB_PASSWORD"
read -r -p "Apply them now? [y/N] " apply
[ "$apply" = "y" ] || { echo "Stopped before applying anything."; exit 1; }
supabase db push --password "$DB_PASSWORD"
unset DB_PASSWORD

echo "3/5  Credential encryption key…"
if ! security find-generic-password -s "$KEK_ITEM" >/dev/null 2>&1; then
  security add-generic-password -a "$USER" -s "$KEK_ITEM" -l "Stock Tracker credential KEK (k1)" \
    -w "$(openssl rand -base64 32)"
  echo "     Generated a new key in Keychain item '$KEK_ITEM'. Back it up in your password manager:"
  echo "     if every copy is lost, stored brokerage credentials cannot be recovered."
fi
KEK="$(security find-generic-password -s "$KEK_ITEM" -w)"
supabase secrets set --project-ref "$REF" CREDENTIAL_KEKS="k1:$KEK" CREDENTIAL_ACTIVE_KEK=k1 >/dev/null
unset KEK

echo "4/5  Deploying Edge Functions…"
supabase functions deploy snaptrade-proxy ai-proxy private-markets account-deletion private-provider-events --project-ref "$REF"

echo "5/5  Smoke test (requests without endpoint credentials must be refused)…"
ANON_KEY="$(supabase projects api-keys --project-ref "$REF" -o json | python3 -c '
import json, sys
keys = json.load(sys.stdin)
pick = next((k for k in keys if k.get("name") == "anon"), None) or next((k for k in keys if k.get("type") == "publishable"), None)
print(pick["api_key"] if pick else "")')"
for fn in snaptrade-proxy ai-proxy private-markets account-deletion private-provider-events; do
  code="$(curl -s -o /dev/null -w '%{http_code}' -X POST "https://$REF.supabase.co/functions/v1/$fn" \
    -H "Authorization: Bearer $ANON_KEY" -H "apikey: $ANON_KEY" -H 'Content-Type: application/json' -d '{}')"
  echo "     $fn without endpoint credentials -> HTTP $code (expected 401)"
done

cat <<EOF

Done. Still yours to do:
  * Provider keys (never paste them into a chat):
      supabase secrets set --project-ref $REF \\
        SNAPTRADE_CLIENT_ID=… SNAPTRADE_CONSUMER_KEY=… GEMINI_API_KEY=… OPENAI_API_KEY=…
  * Auth (dashboard → Authentication): enable Email (+ Apple for Sign in with Apple) and add
    {{ .Token }} to the "Confirm signup" template, as the baseline migration's header explains.
  * Config/Secrets.plist: SupabaseURL = https://$REF.supabase.co, SupabaseAnonKey = the anon or
    publishable key (public by design). Then delete SnapTradeConsumerKey, OpenAIAPIKey and
    GeminiAPIKey from that file.
EOF
