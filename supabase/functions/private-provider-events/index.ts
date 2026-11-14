import { serviceClient } from "../_shared/secure/edge.ts";
import { handleProviderDelivery } from "./handler.ts";

Deno.serve((request) =>
  handleProviderDelivery(request, {
    key: (provider, keyId) => {
      const keyring = JSON.parse(Deno.env.get("PRIVATE_PROVIDER_EVENT_KEYS") ?? "{}");
      const keys = Object.hasOwn(keyring, provider) ? keyring[provider] : null;
      return keys && Object.hasOwn(keys, keyId) && typeof keys[keyId] === "string" ? keys[keyId] : null;
    },
    now: Date.now,
    accept: async (delivery) => {
      const { p_kind, ...event } = delivery;
      const client = serviceClient();
      const { data, error } = p_kind === "account_link"
        ? await client.rpc("redeem_private_account_link", event)
        : Object.hasOwn(event.p_details, "offer_reference")
        ? await client.rpc("accept_private_provider_reference_delivery", delivery)
        : await client.rpc("accept_private_provider_delivery", delivery);
      if (error) throw error;
      return data;
    },
  })
);
