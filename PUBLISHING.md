# Publish Switch UI 1.005.000

1. Extract **SwitchLauncher-main-1.005.000-source.zip**. Upload the contents of its **SwitchLauncher** folder to the repository root on **main**, including the hidden **.github** folder. Upload the source before creating the release tag.
2. Create tag **v1.005.000**, targeting the updated **main** branch.
3. Use release title **Switch UI 1.005.000** and paste **RELEASE-NOTES.md** into the description.
4. Attach **SwitchLauncher-1.005.000.zip**. Its checksum is optional. Attach the installable ZIP, not the source archive or an Actions artifact wrapper.
5. Publish a normal release with **Set as a pre-release** unchecked. Set it as the latest release if desired.
6. Wait for **Publish launcher update feed** to succeed. Existing stable users on a compatible host can then update through About.

The permanent stable feed stays:

```text
https://raw.githubusercontent.com/kasobos67/SwitchLauncher/update-feed/launcher-updates.json
```

The included publisher sets **min_app: 1.005.000** for this release while preserving earlier entries. Upload the updated tools as part of the source so older hosts are not offered this ZIP. Do not upload the test manifest over main or edit the separate test feed. No JSON release asset is needed.

For manual installation, update ProsperoEden to 1.005.000, close the application, extract the installable ZIP and copy its **switch-ui** folder to `/data/prosperoeden/launchers/`. Preserve `/data/prosperoeden/config/launcher-state/switch-ui.json` and the rest of the data directory. The stable ID and state schema are unchanged.

No host fix is included. Direct frame generation method selection remains unavailable on official 1.005.000; the existing built-in-launcher shortcut is retained.
