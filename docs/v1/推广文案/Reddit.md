# Reddit

## Suggested Subreddits

- `r/macapps`
- `r/SideProject`
- `r/indiehackers`
- `r/github`
- `r/programming` only if the post is technical

## Title Options

- I built a native macOS app to organize and research GitHub Stars
- My GitHub Stars became unmanageable, so I built a local-first macOS app for them
- Looking for feedback: Starcat, a GitHub Stars knowledge base for macOS

## Post Draft

I built a macOS app called Starcat because my GitHub Stars stopped being useful.

I had almost two thousand starred repos. Some were tools I wanted to try, some were libraries I used once, some were AI projects I wanted to follow, and a lot were just "I'll read this later." GitHub's Stars page is fine for bookmarking, but it is not great when you want to search, organize, revisit, and compare repos over time.

Starcat syncs Stars locally and gives them a more research-oriented interface:

- three-column native macOS layout;
- local README cache and reader;
- tags, notes, and reading status;
- full-text and semantic search;
- release tracking;
- AI summaries, tag suggestions, translation, and repo chat;
- similar repo recommendations from the detail page.

Screenshots:

![Manage view](assets/01-manage-ungrouped.png)

![Repo detail](assets/02-repo-detail-readme.png)

I am trying to keep the AI features grounded in repo context. It is not meant to be a generic chatbot. The useful part is asking questions while looking at a repo, generating a short summary before reading a README, or getting tag suggestions that you can confirm manually.

The roadmap is more about repo research:

- clean up untagged stars;
- find similar or better-maintained alternatives;
- compare a shortlist of repos before adopting one;
- generate weekly summaries of newly starred repos;
- search your own stars with natural language.

I would love feedback from people who use GitHub Stars heavily. How do you organize them today? What would make you actually go back and use what you starred?
