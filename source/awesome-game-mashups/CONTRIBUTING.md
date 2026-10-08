# Contributing

Made a cross-game project, found a missing demo, or spotted an error? [Submit it](https://github.com/bailo167/awesome-game-mashups/issues/new?template=new-project.yml) or [report a correction](https://github.com/bailo167/awesome-game-mashups/issues/new?template=correction.yml). A GitHub issue is enough; you do not have to write code.

## What belongs here

Substantial cross-game gameplay, runtime integration, embedded emulation and systems recreations. Skins, ordinary asset swaps and a map import alone are not core entries. Historical projects can qualify. The implementation may run in one process or several: judge the interaction, not the process count.

Use `core`, `watchlist` or `adjacent`. A working link is not proof of a working game. A creator video is not a release. Public source is not automatically a ready-to-install download. Preserve those distinctions.

## Evidence first

Prefer the original repository, release, creator project page and technical documentation. Reposts are discovery leads. Describe claimed functionality as documented, not independently tested. Record a licence or AI assistance only when an identified source states it. Unknown is `null`, not a guess. GitHub's `NOASSERTION` is not a licence.

Keep rights separate: source-code licensing does not automatically license screenshots, game assets, videos or music. Link to creator demos. Do not upload game files, private Discord logs, HAR captures, account data or credentials.

## Edit once, generate everything

`data/projects.json` is the project source of truth. `data/site.json` holds editorial settings. README catalogue entries, the weekly digest, the static site and the Atom feed are generated; do not edit those independently.

With **Python 3.12 or newer**, from the repository root:

```sh
python3 scripts/catalogue.py validate
python3 scripts/catalogue.py build
python3 scripts/catalogue.py check
python3 -m unittest discover -s tests -v
python3 -m http.server 8000 --directory _site
```

Open the local server in a browser. There are no runtime JavaScript dependencies or accounts. JavaScript enhances filtering; the catalogue and project pages work without it.

Submit the edited JSON and regenerated `README.md` / `docs/promote/weekly-digest.md` in the same PR. Do not commit `_site/`, build output or temporary files. The main-branch workflow can recover omitted generated files; PR checks intentionally reject drift so contributors see it early.

## Record fields

The editor schema is `data/projects.schema.json`; `scripts/catalogue.py` also validates cross-record rules.

- `id`: stable lower-case hyphenated identifier. Existing IDs and `#project-ID` links must not change on a rename.
- `name`, `summary`, `description`, `guest`, `host`, `creator`: factual description. Summary is one plain-language sentence. Preserve original attribution and upstream credits.
- `category`, `status`: use existing values. `released` requires a real acquisition source; `source-available` requires a code link; `video-only` cannot also mean `released`.
- `source`, `release`, `media`, `creator_post`, `project_page`, `verification`, `extra_links`: public HTTP(S) URLs. Prefer exact primary sources. `media` is a demo link, not an image or repository home page.
- `first_seen`: earliest supported project-publication date. `added_at`: date added to this catalogue. Do not confuse a rediscovered old project with a new release.
- `reviewed_at`, `review_basis`, `review_note`: date, type and scope of the actual check. A URL request does not refresh a source-review date. Inherited entries use `legacy-record` and a null date until reviewed.
- `platforms`, `requirements`: only documented compatibility and ownership requirements; unknown platforms are an empty array.
- `playtest`: null unless actual test evidence exists. A test record needs date, version, platform and evidence. Do not copy a creator's test into the catalogue's independent-play-test field.

The original historical fields remain available. Add new fields deliberately to both schema and validation; do not silently overload existing ones.

## Reviews and safety

Keep PRs focused. Include evidence for status changes and demo links. Do not use HTML, tracking redirects or expiring Discord attachment links as lasting catalogue content. The site escapes text and does not load creator media automatically.

CI validates structure, deterministic generation and tests. The separate reachability audit distinguishes reachable, unavailable and unresolved URLs: 403, 429 and timeouts are unresolved, not verified and not automatically dead. A successful build is not a malware scan or full compatibility test.

Workflow, generator and dependency changes deserve code review. Never run submitted game binaries or privileged PR scripts as part of curation. See the [maintenance contract](.github/CATALOGUE_MAINTENANCE.md) and [deployment guide](docs/MAINTENANCE.md).
