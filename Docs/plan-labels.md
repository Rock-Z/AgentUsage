# Plan labels

Verified against official provider terminology on September 22, 2026:

- OpenAI: https://learn.chatgpt.com/docs/pricing
- Anthropic: https://claude.com/pricing

The Codex card uses ChatGPT plan names: Free, Go, Plus, Pro 5x, Pro 20x,
Business, Enterprise, and Edu. The Claude Code card uses Free, Pro,
Max 5x, Max 20x, Team, and Enterprise.

OpenAI's installed app maps the account identifier `prolite` to Pro 5x and
`pro` to Pro 20x. Both are distinct values in the current Codex app-server
PlanType schema. `team` is the legacy identifier for ChatGPT Business.
Provider names are omitted from labels because the card heading identifies them.
Internal business and education capacity variants retain their public plan
family name; their backend suffixes are not public product names.

Codex labels come from the live `account/rateLimits/read` response, not cached
sign-in account metadata. Claude labels come from the live OAuth profile's
organization type and rate-limit tier together. Profile requests bypass the
HTTP cache. Neither provider's usage percentage is used to infer a plan.

Unknown plan identifiers are omitted rather than turned into invented names.
Max without a recognized tier displays Max. A failed Claude
profile lookup omits the plan label while preserving usage data; it does not
fall back to potentially stale credential metadata.

Codex plan labels refresh with every successful usage fetch. The Claude profile
is requested alongside usage at most once an hour, so the label can lag a plan
change by up to an hour; a failed lookup is retried on the next fetch. Claude
retains its existing 60-second minimum fetch interval and rate-limit backoff;
cached snapshots keep the original Updated timestamp. They are not represented
as freshly fetched.
