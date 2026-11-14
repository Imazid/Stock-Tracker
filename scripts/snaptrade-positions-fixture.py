"""Relay a local Supabase stack and serve SnapTrade positions for AccountSyncTests."""

import base64
import json
import os
from datetime import date, timedelta
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen

SOURCE = "a8cc1385-31a7-4c4d-9955-6789589cc956"
RECEIVER = "0cc77f5f-2b5f-481a-95cb-e44b9c0ad97f"
CONNECTION = "6b72c32d-98b5-49f3-8329-97301f651386"
PHASES = {}


def broker_response(user, request):
    operation = request["operation"]
    if operation == "status":
        return 200, {"registered": True}
    if operation == "listBrokerages":
        return 200, []
    if operation == "listAccounts":
        phase = PHASES.get(user, "initial")
        return 200, [
            {"id": account, "brokerage_authorization": CONNECTION,
             "institution_name": "CommSec", "number": number,
             "positions_status": "disconnected" if phase == "disconnected" and account == SOURCE else "available"}
            for account, number in [(SOURCE, "••••1234"), (RECEIVER, "••••4321")]
        ]
    if operation == "portfolioCash":
        return 200, {"duplicatesSkipped": 1, "accounts": [
            {"id": SOURCE, "label": "CommSec ••••1234", "paper": False, "status": "available",
             "syncedAt": "2026-11-13T03:00:00.000Z", "incomplete": True,
             "balances": [{"currency": "AUD", "amount": "312.34"}, {"currency": "GBP", "amount": None},
                          {"currency": "USD", "amount": "-12.34"}]},
            {"id": RECEIVER, "label": "CommSec ••••4321", "paper": True, "status": "disconnected",
             "syncedAt": None, "balances": []},
        ]}
    if operation == "accountActivities":
        params = request["params"]
        day = params["endDate"]
        if params.get("stockTransfersOnly"):
            account = params["accountId"]
            if account not in (SOURCE, RECEIVER):
                return 404, {"error": {"code": "UNKNOWN_ACCOUNT"}}
            if account == SOURCE and params["offset"] == 0:
                return 200, {"activities": [], "omitted": 0, "nextOffset": 50}
            sending = account == SOURCE
            event_day = (date.fromisoformat(day) - timedelta(days=2 if sending else 1)).isoformat()
            return 200, {"activities": [{
                "id": ("1" if sending else "2") * 64, "date": event_day,
                "stockTransfer": {
                    "accountId": account, "direction": "sent" if sending else "received",
                    "symbol": "BHP.AX" if sending else "BHP", "exchange": "XASX" if sending else "ASX", "shares": "2.25",
                },
            }], "omitted": 0, "nextOffset": None}
        return 200, {"activities": [
            {"id": "d" * 64, "date": day, "label": "Outgoing cash transfer between accounts",
             "amount": -250, "currency": "USD", "cashFlow": {"date": day, "kind": "withdrawal", "amount": 250}},
            {"id": "e" * 64, "date": day, "label": "Incoming cash transfer between accounts",
             "amount": 250, "currency": "AUD",
             "foreignCashFlow": {"date": day, "kind": "deposit", "amount": "250", "currency": "AUD"}},
            {"id": "a" * 64, "date": day, "label": "Cash contribution", "amount": 600, "currency": "USD",
             "cashFlow": {"date": day, "kind": "deposit", "amount": 600}},
        ], "omitted": 0, "nextOffset": None, "snapshot": None, "syncedAt": None}
    if operation != "accountAllPositions":
        return 400, {"error": {"code": "UNEXPECTED_OPERATION"}}
    account = request["params"]["accountId"]
    if account not in (SOURCE, RECEIVER):
        return 404, {"error": {"code": "UNKNOWN_ACCOUNT"}}
    phase = PHASES.get(user, "initial")
    if phase == "failure" and account == SOURCE:
        return 502, {"error": {"code": "SNAPTRADE_UPSTREAM", "message": "temporarily unavailable"}}
    quantities = {SOURCE: "50", RECEIVER: "20"} if phase == "initial" else {SOURCE: "0", RECEIVER: "70"}
    return 200, {"results": [
        {"instrument": {"kind": "stock", "symbol": "BHP.AX", "exchange": "XASX", "currency": "AUD"},
         "units": quantities[account], "price": "59.50", "cost_basis": "39.5", "currency": "AUD"},
        {"instrument": {"kind": "option"}, "units": "3"},
        {"instrument": {"kind": "mutualfund"}, "units": "15", "cash_equivalent": True},
    ], "data_freshness": {"as_of": "2026-11-13T03:00:00Z"}}


class FixtureRelay(BaseHTTPRequestHandler):
    def relay(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0"))) or None
        if self.path.startswith("/qa/broker-positions/") or self.path == "/functions/v1/snaptrade-proxy":
            token = self.headers.get("Authorization", "").split(".")
            try:
                user = json.loads(base64.urlsafe_b64decode(token[1] + "=" * (-len(token[1]) % 4)))["sub"]
            except (IndexError, KeyError, ValueError):
                self.respond(401, b"{}")
                return
            if self.path == "/functions/v1/snaptrade-proxy":
                status, payload = broker_response(user, json.loads(body))
                self.respond(status, json.dumps(payload).encode())
            else:
                phase = self.path.rsplit("/", 1)[1]
                if phase not in ("disconnected", "failure", "transfer"):
                    self.respond(404, b"{}")
                    return
                PHASES[user] = phase
                self.respond(200, b"{}")
            return

        if not self.path.startswith(("/auth/v1/", "/rest/v1/")):
            self.respond(503, b"{}")
            return
        headers = {name: self.headers[name] for name in
                   ("apikey", "Authorization", "Content-Type", "Prefer", "Accept", "Range", "Range-Unit")
                   if name in self.headers}
        request = Request("http://127.0.0.1:58321" + self.path, data=body, headers=headers, method=self.command)
        try:
            with urlopen(request, timeout=10) as response:
                self.respond(response.status, response.read())
        except HTTPError as error:
            self.respond(error.code, error.read())

    def respond(self, status, data):
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    do_GET = do_POST = do_PATCH = do_DELETE = relay


if __name__ == "__main__":
    port = int(os.environ.get("STOCK_TRACKER_QA_PORT", "58346"))
    ThreadingHTTPServer(("127.0.0.1", port), FixtureRelay).serve_forever()
