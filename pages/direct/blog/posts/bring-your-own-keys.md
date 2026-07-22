---
title: Bring Your Own Keys — AI Without a Black Box Default
date: 2026-07-19
summary: Starcat's AI path is BYOK-first: your provider, your keys, your rate limits — and your library stays local.
author: Starcat
---

"Just upload your data for better AI" is a common pitch. For a personal starred library, it is the wrong default.

Starcat's AI features are built around **BYOK** — bring your own keys — so models run through *your* provider settings instead of quietly shipping your notes into someone else's training-shaped void.

## What BYOK actually buys you

1. **Choice** — pick the provider and model that fit cost, latency, and quality
2. **Boundary** — keys live in Keychain-backed storage on your Mac; the app does not invent a second identity for your library
3. **Accountability** — usage and failures are yours to see, not buried in a opaque pooled meter

Pro unlocks the capability. BYOK keeps the control surface honest.

## Local library, remote models

The split is intentional:

- **Local**: Stars cache, tags, notes, status, search indexes, RAG chunks
- **Remote (optional)**: inference and embeddings when you ask for them

That means AI is a tool you switch on for a job, not a cloud that owns the filing cabinet.

## Practical advice

- Start with one provider you already trust for other work
- Prefer models you can afford to run on "suggest tags for this repo" without flinching
- Keep the confirmation rule: suggestions are drafts until you accept them

If a product only works when it holds your API relationship and your corpus, you are renting both. Starcat tries to rent neither by default.
