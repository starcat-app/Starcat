# External Search Provider View And Context Aggregation

Starcat keeps the global Web search tab as a single External Search Provider view, while allowing aggregate search only for External Context used by AI features, only for Pro users, and only after the user enables that setting. This preserves transparent search source, quota use, and UI behavior in Search Center, while still letting AI features gather broader context when the user explicitly accepts the extra cost, latency, and external requests.

**Status**: accepted

**Considered Options**: We considered making Web search aggregate all configured providers by default, but rejected it because it would make result provenance, error handling, de-duplication, latency, and third-party quota usage unclear. We also considered forbidding aggregation entirely, but kept it as an explicit Pro-only External Context mode because AI summaries can benefit from broader source coverage.

**Consequences**: Web search remains a Provider View and never silently fans out to every provider. Single-Provider External Context remains available without Pro gating when the selected provider is enabled and usable. Aggregate External Context Search can query every enabled and usable provider only when the Pro-only aggregate setting is on, partial provider failures still allow partial context, and merged context is capped by an explicit result budget.
