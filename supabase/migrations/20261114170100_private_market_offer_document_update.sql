-- Record the fact that the issuer dated a public disclosure document. The
-- catalogue keeps this round's availability unverified.
insert into public.corporate_actions (company_id, title, significance, published_at, source_url, published)
values ('d72c4060-1ae7-4a2f-8f2e-9f4bf1577e03', 'Crowd-sourced funding document published',
  'Art Play Productions dated its public offer document 10 November 2026. The document gives proposed terms and names Birchal Financial Services as intermediary. Current offer availability requires confirmation.',
  '2026-11-10 00:00:00+11',
  'https://storage.googleapis.com/birchal-uploads/209b02ce-0064-41f7-9434-3cc5cb24c84c/209b02ce-0064-41f7-9434-3cc5cb24c84c.pdf', true);
