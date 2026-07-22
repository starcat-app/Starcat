---
title: Why Starcat Is Native macOS — Not Electron
date: 2026-07-15
summary: Native is not nostalgia. For a tool you live in every day, platform fit is a product feature.
author: Starcat
---

Cross-platform frameworks are a reasonable default for many products. Starcat is not one of them.

We build a native macOS app (SwiftUI, macOS 15+) because the product is a daily workstation surface: three-column browsing, system-consistent panels, local databases, Keychain-backed secrets, and background work that should feel like other Mac apps — not like a browser tab wearing an icon.

## What native buys you

- **Fit with the OS** — windowing, menus, keyboard focus, and settings patterns people already know
- **Local systems access without apology** — SQLite, Keychain, notifications, and sandbox rules that match Apple's model
- **Performance where it matters** — large starred libraries and long README sessions should not feel like a website under load

Electron can ship faster across platforms. It also tends to ship "almost Mac" forever. For Starcat, almost is not enough.

## The trade-off we accept

Native means we focus. The short-term priority is making the Mac app stable and useful. Multi-platform builds are not promised on the marketing page because we refuse to pretend otherwise.

If you live in a browser-only workflow, Starcat may not be your tool. If you live on a Mac and want GitHub Stars to behave like a real desktop library, native is the point — not a constraint we are waiting to escape.
