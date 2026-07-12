# Implementation kickoff (for Claude Code)

Paste this as the first message to Claude Code in this repo to begin the build.

---

You are working in **Rewind**, an open-source cross-platform (Windows + macOS)
instant-replay / auto-clip app. Read `CLAUDE.md`, `ARCHITECTURE.md`, and
`ROADMAP.md` first — they define the design and the milestones.

Use a brainstorming-first approach:

1. **Brainstorm & plan.** Turn ROADMAP milestone **v0.1 ("It records")** into a
   concrete task breakdown. Confirm the plan with me before coding.
2. **Implement v0.1** end-to-end in "dev mode" (stub shim), then wire real
   libobs behind the C shim (`native/shim/`). Keep the C surface tiny.
3. **Then v0.2** (League event auto-clipping) and **v0.3** (storage-aware
   retention + pinning) per the roadmap.

Hard constraints:
- Keep it **extensible**: new games = one new `GameEventSource` + registry
  entry, nothing else. Support multiple games at once (cross-game).
- **Storage-aware**: never auto-delete protected/pinned clips.
- Update docs (README/ROADMAP/ARCHITECTURE/CHANGELOG) in the same change as any
  behavior change. Use Conventional Commits.
- License stays **GPLv3** (libobs is embedded).

Start by reading the docs and proposing the v0.1 task breakdown.
