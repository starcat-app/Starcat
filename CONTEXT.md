# Starcat

Starcat is a GitHub Star management and knowledge-work app. This context defines product language that must stay consistent across UI, docs, and implementation discussions.

## Language

### Search

**External Search**:
Third-party web search that Starcat uses to find public network materials outside the local Starcat library. A provider can be AnySearch, Tavily, Exa, or Brave LLM Context.
_Avoid_: External semantic search, semantic web search

**Local Semantic Search**:
Search over Starcat's local repo embeddings and similarity scores. It is separate from third-party web search even when the external provider uses semantic ranking internally.
_Avoid_: External search, web search

**External Context**:
External Search results after they are shaped into material for Starcat AI features. It is a user-controlled permission boundary for AI context, not a summary-only feature and not a new local repo record by itself.
_Avoid_: AI summary context, search provider, semantic search

**External Search Provider**:
A third-party service that implements External Search for Starcat. One External Search Provider can supply many results, and one Starcat user can configure multiple External Search Providers.
_Avoid_: Provider, search tab, model provider

**Provider View**:
The Web search view for one selected External Search Provider. It is not an aggregated view across every configured External Search Provider.
_Avoid_: Provider aggregation, all-provider search

**Automatic Provider Selection**:
A fallback policy for External Context that chooses the first usable External Search Provider from the user's Enabled Providers. It never enables a Provider automatically, and explicit External Search Provider choices never fallback silently.
_Avoid_: Default provider, provider aggregation

**Aggregate External Context Search**:
An optional Pro-only External Context mode that queries every enabled and usable External Search Provider, then merges their External Search Results for AI features. It does not affect the Web tab.
_Avoid_: Web aggregation, all-provider Web search

**Single-Provider External Context**:
External Context built from one selected or automatically selected External Search Provider. It is available to non-Pro users when the Provider itself is enabled and usable.
_Avoid_: Aggregate external context, Pro-only external context

**External Context Result Budget**:
The limit on how many External Search Results can enter AI context. In aggregate mode, Starcat takes up to three results per Provider query, deduplicates by URL, and keeps at most eight results.
_Avoid_: Unlimited provider results, full search dump

**Partial External Context**:
External Context built from the successful Providers when one or more Providers fail in aggregate mode. Partial External Context can still be used by AI features.
_Avoid_: Failed context, all-or-nothing context

**Enabled Provider**:
An External Search Provider that the user has explicitly allowed Starcat to call. Anonymous availability does not make an External Search Provider enabled by default.
_Avoid_: Available provider, default provider

**Usable Provider**:
An Enabled Provider that also has the credential or anonymous capability required for the requested operation. A stored API key alone does not make a disabled Provider usable.
_Avoid_: Configured provider, keyed provider

**Private External Search Boundary**:
The privacy rule for private repositories when External Context is allowed. Starcat may send the repository full name to an Enabled Provider, but not README content, notes, tags, code context, or description.
_Avoid_: Private AI context, full private context

**Local Provider Credential**:
An API key for an External Search Provider stored only on the current device. It is not CloudKit data and does not sync between devices.
_Avoid_: Synced provider key, account provider key

**Verified Provider Credential**:
A Local Provider Credential that has passed the provider's test request on this device. Verification is local state and must be cleared when the key changes or the provider reports it invalid.
_Avoid_: Existing key, synced verification

**External Search Result**:
A reference returned by an External Search Provider. It is not a Starcat repository record and must not enter the local library unless the user performs a separate explicit import or add action.
_Avoid_: Repo candidate, library item

**External Context Cache Key**:
The cache identity for External Context, based on the repository identity, selected External Search Provider, and the query fingerprint. It should change when the outbound search queries change.
_Avoid_: Repo-only context cache

**Provider Context Cache**:
The per-Provider cache entry used to build External Context. Aggregate External Context Search merges Provider Context Cache entries at runtime and does not cache the aggregate as its own record.
_Avoid_: Aggregate context cache, merged provider cache

## Example Dialogue

Dev: Should AI summaries use Local Semantic Search or External Search?

Domain expert: Use External Search only when the user enables External Context. Local Semantic Search means matching against Starcat's own indexed repos.

Dev: If Exa uses semantic ranking, should we call it External Semantic Search?

Domain expert: No. In Starcat language it is still External Search. Local Semantic Search is reserved for local embedding search.

Dev: In the Web tab, should Starcat query every configured Provider?

Domain expert: No. The Web tab shows the current Provider View. Searching all External Search Providers would be a separate explicit action.

Dev: If the user explicitly selects Exa but removes the API key, should Starcat use Tavily instead?

Domain expert: No. Only Automatic Provider Selection can fallback. Explicit External Search Provider choices should surface that Exa is unavailable.

Dev: If Aggregate External Context Search is enabled, does the Web tab search every provider too?

Domain expert: No. Aggregation only applies to External Context for AI features. The Web tab remains a Provider View.

Dev: If four External Search Providers are enabled, should all their results enter the prompt?

Domain expert: No. External Context has a result budget; aggregate mode keeps broad coverage without dumping every result into AI context.

Dev: If Tavily fails but Exa returns useful results, should AI lose all External Context?

Domain expert: No. That is Partial External Context and should still be used.

Dev: Since AnySearch can run anonymously, should Starcat call it before the user enables it?

Domain expert: No. Anonymous support only means no API key is required after the External Search Provider is enabled.

Dev: Can Automatic Provider Selection use AnySearch anonymously before the user enables AnySearch?

Domain expert: No. Automatic only chooses among Enabled Providers.

Dev: If External Context is allowed for a private repository, can Starcat send the README to Exa?

Domain expert: No. The Private External Search Boundary allows only the repository full name to leave Starcat.

Dev: Should an Exa API key configured on one Mac appear on another Mac through CloudKit?

Domain expert: No. It is a Local Provider Credential and must be configured per device.

Dev: If Exa returns a GitHub repository URL, should Starcat automatically add that repo to the local database?

Domain expert: No. It is still an External Search Result until the user explicitly imports or adds it.

Dev: If the repo description changes and Starcat builds different external search queries, should cached External Context still be reused?

Domain expert: No. The External Context Cache Key includes the query fingerprint, so changed outbound queries miss the cache.

Dev: Should Starcat cache one merged result for aggregate External Context?

Domain expert: No. Cache each Provider result separately; aggregation is a runtime merge.
