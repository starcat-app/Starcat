---
title: Stay on GitHub Pages Without Losing Your Library Context
date: 2026-07-14
summary: The browser Companion keeps notes, tags, and Starcat context next to the repository you are already reading.
author: Starcat
---

Most of the time you discover repositories in the browser. Most of the time your personal metadata lives somewhere else.

That split is how notes get lost. You read a README on github.com, think "I should tag this `infra/queue`," and never open the desktop app.

## Companion as the bridge

Starcat's browser Companion (Chrome / Safari) is meant to sit beside GitHub pages: same repository, local context — notes, tags, health signals, recommendations — without forcing a full context switch for every glance.

The desktop app remains the library. The Companion is the lane change.

## What stays local

Pairing talks to Starcat on your machine. The point is not to rebuild Starcat inside a content script. The point is to surface *your* data where your eyes already are.

If the app is closed or unpaired, the Companion should fail clearly — not invent a second cloud account for convenience.

## A workflow that sticks

1. Star something interesting on GitHub
2. Add one tag or one sentence of notes from the Companion while the reason is fresh
3. Later, use Starcat search / RAG when you need to find it again

The Companion does not replace the three-column Mac app. It reduces the number of times good intentions die in a browser tab.
