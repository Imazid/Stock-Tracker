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
      const { data, error } = await serviceClient().rpc("accept_private_provider_delivery", delivery);
      if (error) throw error;
      return data;
    },
  })
);
