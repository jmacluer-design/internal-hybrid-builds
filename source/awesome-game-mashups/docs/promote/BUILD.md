# Rebuild the original promotional assets

The optional renderer creates an original directory preview, not a gameplay montage. It uses the generated catalogue UI and its own title cards; no creator footage, game assets, browser session or external media is downloaded.

Requirements: Python 3.12+, FFmpeg with the libx264 encoder, and Playwright/Chromium. From the repository root on macOS or Linux:

```sh
python3 scripts/catalogue.py build
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r tests/browser-requirements.txt
python -m playwright install chromium
python scripts/render_promo.py
```

An existing Chromium installation can be selected with `--chromium /path/to/chromium`. Use `--output /path/to/output` to change the destination. FFmpeg must be installed separately and available on PATH.

Outputs under `build/promo/`:

- `social-preview.png`: 1280×640 original repository card, with the current catalogue count.
- `directory-walkthrough.mp4`: a silent 30-second, 1080×1920 H.264 vertical preview made from six five-second title/UI frames.
- `01.png` through `06.png`: individual frames for reviewing or editing the sequence.

The video explicitly says it is a directory walkthrough / website preview, not gameplay. Review the generated frames for legibility before publishing. Counts describe catalogue entries, which include development, unconfirmed and related material; they do not mean all entries are verified releases.

GitHub does not apply the social image merely because it exists in a repository. The owner uploads it in **Settings → General → Social preview → Edit → Upload an image**. Before advertising a public website address, finish the [Pages activation and readback](../MAINTENANCE.md#publishing-the-site).

Generated media stays outside source control. Keep the script and documentation in GitHub, and retain actual output as build artifacts or approved social uploads. Linking a creator demo is permitted by the catalogue's workflow; re-uploading that footage requires a separate rights check. See the [media guide](README.md) for the permission-request draft.
