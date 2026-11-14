-- Owner-scoped timeline pages and per-proposal approval history.
create index if not exists agent_runs_user_agent_seq_idx on public.agent_runs (user_id, agent_id, seq desc);
create index if not exists audit_events_user_proposal_sequence_idx on public.audit_events (user_id, proposal_id, sequence)
  where proposal_id is not null and kind in ('proposalApproved', 'proposalRejected');
