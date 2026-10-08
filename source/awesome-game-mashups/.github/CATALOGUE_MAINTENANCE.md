# Catalogue maintenance contract

The live default branch is the source of truth. A remembered count, previous chat, audit report or checkpoint is a lead until checked against current files. The repository, not a report, is the deliverable.

## Completion

Use one exact outcome: `COMPLETE — PUBLISHED AND VERIFIED`, `COMPLETE — VERIFIED NO CHANGES REQUIRED`, `PARTIAL — SOME CHANGES PUBLISHED; WORK REMAINS`, or `BLOCKED — REQUIRED GITHUB PUBLICATION NOT COMPLETED`.

Research, local files, an unmerged branch, or one successful commit while justified work remains is not completion. Never claim a site is live just because its source or build artifact exists.

## Start

Read live README, `data/projects.json`, `data/site.json`, `data/projects.schema.json`, CONTRIBUTING, this contract, `.github/catalogue-state.json`, templates, workflows and LICENSE. Read metadata, recent commits, open issues/PRs and Actions. Confirm legitimate write access; no dummy files or bootstrap workflows just to test permissions. The checkpoint never overrides contradictory live data.

Repository permission flags are not a successful publication test. Before extended discovery, independently verify and publish the smallest genuine outstanding correction when one exists, then read it back. If there is no justified change yet, do not manufacture one. Discover the current tool schemas rather than copying tool names or arguments from old chats.

## Research

Search new and historical cross-game work across primary repositories/forges, creator sites, Steam Workshop, Nexus Mods, ModDB, itch.io, YouTube, Reddit, X, Bluesky, relevant forums, technical blogs and recomp/decomp communities. Follow creator/upstream credits; do not limit discovery to Minecraft. Search game-inside-game, cross-game mod, runtime rewrite, source port, emulation and substantial systems recreation variants.

Recheck existing entries for new releases, repositories, moves, archive/dead status, platforms, requirements, licence changes, technical scope and creator corrections. Prioritize missing demos, undocumented requirements, stale reviews and unresolved links as well as new projects.

Evidence preference: original repository, original release, creator project page, creator footage, technical docs, then secondary corroboration. Distinguish creator/repost, original/fork, source/download and documented/independently demonstrated behaviour. Never infer licences, creators, AI use, platform support or play-testing. Record AI assistance only when documented.

## Inclusion and evidence

Core means substantial runtime, gameplay, systems, embedded emulation or cross-engine interaction. Ordinary skins, model swaps, themed maps, weapon packs and art are not core alone. One process versus several is an implementation detail, not automatic inclusion/exclusion. Historical precursors can remain useful. Related/borderline projects stay `adjacent`; claims lacking sufficient support stay `watchlist`.

Use the least-strong supported status. Video is not a release. Public code is not a ready-to-install download. A 2xx URL response is not source verification, a safe binary or a successful play-test. Do not silently promote watchlist claims or describe all catalogue entries as verified games.

## Canonical data and generation

Edit project content only in `data/projects.json`. Editorial settings belong in `data/site.json`. Preserve stable IDs and the existing `#project-ID` anchors. Preserve historical metadata and primary links when renaming or updating entries.

`first_seen` is project history; `added_at` is the actual catalogue addition date. Set `reviewed_at`, `review_basis` and a scoped `review_note` only after a real source review. `playtest` remains null unless actual date/version/platform/evidence are recorded. Creator tests are not catalogue play-tests. Unknown data must remain unknown.

Use Python 3.12+:

```sh
python3 scripts/catalogue.py validate
python3 scripts/catalogue.py build
python3 scripts/catalogue.py check
python3 -m unittest discover -s tests -v
```

The README, weekly digest, static website, project pages and feed are generated. Never maintain README entries independently or commit `_site/`. Overview tables are exactly `Project | What it is | Status | Demo`, split into playable, code/development, unconfirmed and related sections. Keep source/release/demo labels explicit and each detailed entry's back link. Do not restore the removed Links/Check links badge.

The main-only workflow can recover omitted generated files, but review the resulting commit. Normal contributions should publish JSON and generated views atomically. A no-op run must not create a meaningless commit.

## Issue and PR handling

Review every open issue and PR each research cycle. Independently verify submissions and corrections; detect duplicates; apply existing labels; resolve valid entries and comment with the relevant publication. Close only genuinely resolved, invalid or duplicate issues, not legitimate unanswered ones.

Read full PR diffs and evidence. Check validity, generation, tests, status claims, links, attribution and rights. Merge correct scoped catalogue changes when allowed, preferring squash. Request concrete changes on material problems. Do not auto-approve workflow, generator or dependency changes just because other checks pass. Public PRs run read-only; never use privileged untrusted checkout or execute submitted game software.

## Publication

Work in coherent batches of roughly 5–10 new projects plus relevant corrections. Publish verified batches while continuing discovery, rather than leaving all writes until the end. Prefer atomic commits. Refresh current main before every later write; reconcile conflicts without force-push or overwriting unrelated work.

After every batch, confirm branch and SHA, read files back, inspect diff, validate/generate/check again, inspect applicable Actions, investigate actionable failures and publish fixes. Keep the repo clean: no HAR exports, private logs, temporary/debug/bootstrap artifacts or unlicensed game media.

## Reachability and site

Inspect `Catalogue integrity`, browser test output, deployment and the latest `Check links` report separately. Unavailable and unresolved URLs are distinct. Never accept 403/429 as successful verification or suppress a broad domain just to obtain green CI. Preserve useful historical context and find a verified replacement before changing source links.

Owner Pages enablement is required. Read `docs/MAINTENANCE.md`; never bypass permissions. Only set `site_enabled` after the actual home page, assets, a detail page, feed and build-info readback succeed. A downloadable website artifact is not a live deployment. Original promotional walkthroughs may use the catalogue UI; gameplay montages require creator permissions. Read `docs/promote/README.md`.

## Failures and checkpoint

Make bounded retries for ordinary technical errors after refreshing state. Use another supported authorized method only for technical failure, never to bypass authentication, permission, branch-protection or safety controls. Report the exact safe error, what reached GitHub and what did not; retain recoverable validated work.

Never disable the scheduled research task because publication failed. Leave it enabled for the next cycle. Only advance the completed research-cycle checkpoint after its stated scope truly completes. Structural upgrades and partial reviews need separate explicit checkpoints, not rewritten historical full-audit dates.

Before finishing, confirm final remote head, intended files, JSON validity, duplicate absence, stable navigation, generated-view agreement, issue/PR outcomes, Actions results, hosting status and remaining evidence gaps. Include the repository/commit links and an honest scope summary.

## Publication incident handling

Scheduled execution maintains the catalogue, not its scheduler. Do not call automation create, update, pause, disable or delete operations during a scheduled catalogue run. A separate explicit maintainer request is required to change the task. Failure is not such a request. This is an execution rule, not a claim that the scheduler has a technical permission lock.

Classify a failure using the actual tool result:

- **Transient transport/service error:** bounded retries, respecting rate limits; refresh remote state before retrying writes.
- **GitHub conflict:** re-read and reconcile; never overwrite concurrent work or force-push.
- **GitHub authorization/protection rejection:** record the HTTP status and relevant permission boundary; do not change permissions to get past it.
- **Approval required:** report the pending approval accurately. Do not call it a GitHub outage or a safety denial.
- **Platform safety denial:** preserve the exact message and any provided request identifier privately. Stop that denied operation and do not retry it through a different tool, credential, encoded payload, issue-to-commit proxy or workflow. Continue independent read-only work where useful.
- **Unknown cause:** say unknown. Do not invent a safety-layer explanation, a GitHub response, a request ID, or a diagnosis about payload size.

App permission settings and provider permissions are separate from platform safety review. A successful interactive write does not establish that a later unattended write will be accepted. Prompt changes, smaller batches and a healthy generator are not proof that an external denial is permanently fixed.

For repeated unexplained platform denials, retain a private support record with the task identifier, times/timezone, exact messages, affected public paths, baseline/readback SHAs and observed app/provider permissions. Never publish private support identifiers, credentials, cookies, HAR captures or account diagnostics in this public repository. The maintainer can submit the sanitized record to the platform provider; do not claim a support case has been submitted without an actual submission result.

Preserve the last completed research checkpoint during an incident. An independent stale-checkpoint alert must not be silenced by advancing dates, counting a structural build as research, or disabling the alert. No-op and partial runs remain explicitly distinct from completed full cycles.
