-- Auth's database role can cascade a user deletion but cannot update public
-- holdings. Revision invalidation is an internal trigger scoped to the exact
-- owner and holding from the affected transaction.
alter function portfolio_sync.touch_transaction_holding_revision() security definer;
