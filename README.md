# SwitchLauncher

A Nintendo Switch-inspired launcher for [ProsperoEden](https://github.com/blackbearreloaded/ProsperoEden) on PS5, maintained by [kasobos67](https://github.com/kasobos67).

SwitchLauncher brings the custom **Switch UI** interface to ProsperoEden as an installable Lua launcher pack. It provides its own HOME screen, software library, menus, artwork, transitions and interface sounds while using ProsperoEden's existing emulation backend and services. It is not compatible with the older, prebuilt SwitchPS5 app

## Compatibility

Minimum required ProsperoEden version: **1.004.000**.

## Interface

![Switch UI HOME screen](docs/images/1.jpg)

![All Software library](docs/images/2.jpg)

![Profile icon selection](docs/images/3.jpg)

![Performance settings](docs/images/4.jpg)

Screenshots supplied by the project author. Games shown are not included.

- Switch-inspired HOME screen with twelve game positions, light/dark blank tiles, library navigation and title bubbles.
- Profile selection and profile artwork.
- Light and dark appearances, transitions and the original interface sound mapping.
- Dedicated controllers, multiplayer and game-files shortcuts.
- Access to supported ProsperoEden settings and services.
- Launcher updates in About, with a separate Credits window.
- A **ProsperoEden Update** dialog for application updates, using the same progress-bar style as launcher updates.
- Optimized Lua drawing, query and layout handling.

The interface is English-only and uses a fixed layout. New ProsperoEden features may require an updated launcher before controls for them appear here.

## Installation

Install or update to the official **ProsperoEden 1.004.000** app before adding this pack.

1. Download the attached **`SwitchLauncher-<version>.zip`** from this repository's [Releases](https://github.com/kasobos67/SwitchLauncher/releases). Use the named launcher ZIP, rather than GitHub's automatically generated source-code archive.
2. Close ProsperoEden completely.
3. Extract the ZIP. It contains a folder named **`switch-ui`**.
4. Using your usual PS5 file-transfer method, copy that folder into:

   ```text
   /data/prosperoeden/launchers/
   ```

   The resulting path must be:

   ```text
   /data/prosperoeden/launchers/switch-ui/manifest.json
   ```

5. Open ProsperoEden. In its built-in interface, go to **Settings → Appearance → Launcher**, then select **Switch UI**.

Keep the folder name `switch-ui`. The repository is called SwitchLauncher, while the internal pack ID remains `switch-ui` to preserve existing launcher state.

The pack uses your established `/data/prosperoeden` data. It does not replace the application executable, emulator core, profiles, game folders or save data. A standalone SwitchPS5 installation is not needed.

### Moving from an earlier test pack

If your installed pack already uses the SwitchLauncher feed below, install this version through **About → Check for updates → Update** after updating ProsperoEden. There is no need to copy the pack again.

Earlier test packs using another repository/feed need one manual installation using the steps above. Ordinary updates deliberately cannot change the feed address.

Preserve this file when replacing the pack:

```text
/data/prosperoeden/config/launcher-state/switch-ui.json
```

That keeps launcher-specific choices such as the light/dark appearance, profile artwork and recent-game ordering. Do not delete the surrounding data folder, profiles or saves.

## How updates work

**SwitchLauncher updates and ProsperoEden application updates are separate.**

| Update | What it updates | Where it comes from |
| --- | --- | --- |
| ProsperoEden application update | The application, emulation backend and native services | The **ProsperoEden Update** dialog and ProsperoEden's own update system |
| SwitchLauncher update | This launcher's Lua code, layout, artwork and sounds | This repository's launcher releases |

Updating SwitchLauncher does not update the emulator. Updating ProsperoEden does not automatically update this launcher. Compatible application updates preserve the launcher in the data directory.

Once this pack is installed, open **About** from the HOME screen, choose **Check for updates**, then **Update** when a compatible release is offered. With automatic launcher checks enabled, Switch UI requests a background check after boot and after returning from a game. **Updates are installed only after confirmation.**

Each release has its own version and download link. The application reads a permanent feed at:

```text
https://raw.githubusercontent.com/kasobos67/SwitchLauncher/update-feed/launcher-updates.json
```

Publishing a stable release runs the repository workflow. It validates the uploaded launcher ZIP and updates that feed with its version, download address, size, checksum and compatibility requirements. Older compatible entries are retained, and the host chooses the newest version it can run. Drafts and prereleases are excluded from the stable feed.

The host validates the downloaded pack, preserves saved state and retains the previous version for recovery. No GitHub account or token is needed on the PS5.

### Will another manual installation be needed?

Normal compatible launcher updates can be installed through About. A manual installation may still be needed if the permanent repository/feed address changes or the installed host can no longer open the pack. A release requiring a newer ProsperoEden version is offered only after the host meets its compatibility requirements; update the application first, then check for the launcher update again. Saved-state schema changes require an explicit migration rather than being silently installed. Changing the publisher is intentionally not an ordinary automatic update.

Launcher versions are independent of ProsperoEden versions. A new backend setting is not automatically added to this fixed interface; the launcher author must expose it in a later pack update. Users can receive that change through this repository's updater without rebuilding ProsperoEden.

## Returning to the built-in launcher

In Switch UI, open **System Settings → Themes → Launcher**, then choose **Built-in launcher**.

If the interface cannot open, close the app and create an empty file at:

```text
/data/prosperoeden/config/force-builtin-launcher
```

Restart the app to use the built-in interface. Remove that recovery file before selecting an external launcher again. The installed pack and saved launcher state can remain in place.

## Source and releases

This repository contains the launcher and its release tools. ProsperoEden itself remains in the [upstream repository](https://github.com/blackbearreloaded/ProsperoEden).

```text
src/                  Lua presentation and motion source
assets/               Artwork, font and sound resources
manifest.json         Pack identity, version and permanent update address
loading.json          Loading-screen presentation
tools/                Local pack builder and release-feed publisher
tests/                Packaging and publisher tests
.github/workflows/    Stable-feed publication workflow
```

One large artwork atlas is stored as `.tga.gz` so the complete source can be uploaded through GitHub's website. The pack builder restores the original TGA bytes; the installed artwork is unchanged. The source archive therefore needs packaging before it can be installed.

### Build an installable ZIP

Python 3.10 or newer is sufficient. No Git command, emulator compilation or extra Python package is required.

```sh
python tools/build_release.py
```

This creates `dist/SwitchLauncher-<version>.zip` and its SHA-256 file. The builder combines the Lua source, inserts the manifest version and restores the compressed source atlas. Development tools and screenshots are omitted from the installed pack.

Run the tests with:

```sh
python -m unittest discover -s tests -v
```

### Publish a versioned release

1. Update the launcher source and set a new three-part numeric version in `manifest.json`.
2. Build and test the pack. Keep `id`, `state_schema` and the permanent feed unchanged unless deliberately planning a migration.
3. Upload the updated repository files through GitHub's website.
4. Create a release using the matching **`v<version>`** tag, targeting the uploaded source.
5. Attach **`SwitchLauncher-<version>.zip`** before publishing. Its checksum file can be attached too.
6. Publish as a stable release, then wait for **Actions → Publish launcher update feed** to finish.

The workflow uses the repository's built-in token with Contents write permission. It creates the `update-feed` branch on first publication. The first feed becomes available after that run; no manually uploaded feed asset is needed.

Do not replace a published version's ZIP. Publish a new version instead. If publication needs retrying, use **Actions → Publish launcher update feed → Run workflow**, enter the existing tag and run it from the default branch. The publisher rejects changed archives for an existing version.

Keep this repository public and retain the feed branch. Repository rules must allow the workflow to update it. This release sets `MIN_APP` to `1.004.000` in `tools/publish_feed.py`; the feed keeps earlier compatible entries for older hosts. Before publishing a later pack that needs a newer host, update that minimum and the manifest's API/capability requirements as appropriate.

## Credits and licensing

- **Eden developers and contributors:** emulation core.
- **[BlackBearReloaded](https://github.com/blackbearreloaded):** ProsperoEden and its PS5 port.
- **[kasobos67](https://github.com/kasobos67):** Switch UI integration and SwitchLauncher maintenance.
- **Nintendo:** original Switch interface artwork, profile resources, font resources and interface recordings used by this presentation.

Nintendo-derived resources were extracted from decrypted Switch firmware to reproduce the original presentation and sound mapping faithfully. No firmware dump, decryption keys, games, saves or account credentials are included.

Project source code is covered by [GPL-3.0-or-later](LICENSE). Third-party resources retain their owners' rights and are described in [ASSET_NOTICES.md](ASSET_NOTICES.md); that code license does not relicense them. SwitchLauncher is an independent project and is not affiliated with Nintendo or Sony.
