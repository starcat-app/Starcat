# External Search Provider View And Context Aggregation

Starcat keeps the global Web search tab as a single External Search Provider view, while allowing aggregate search only for External Context used by AI features and only after the user enables that setting. This preserves transparent search source, quota use, and UI behavior in Search Center, while still letting AI features gather broader context when the user explicitly accepts the extra cost, latency, and external requests.

**Status**: accepted

**Considered Options**: We considered making Web search aggregate all configured providers by default, but rejected it because it would make result provenance, error handling, de-duplication, latency, and third-party quota usage unclear. We also considered forbidding aggregation entirely, but kept it as an explicit External Context mode because AI summaries can benefit from broader source coverage.

**Consequences**: Web search remains a Provider View and never silently fans out to every provider. External Context defaults to one provider, can use Automatic Provider Selection, and can aggregate every enabled and usable provider only when the aggregate setting is on.
