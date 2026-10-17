# Build a stable release from an already-published test

This manual action prepares a stable installable ZIP from a test release that users have already tested. It uses that release's exact tagged source, verifies that it matches the published test ZIP, and converts the package to the stable launcher identity and feed. It does not publish anything or change either update feed.

Verification tolerates Windows/Linux line-ending differences in the README, license and asset notices, which GitHub's upload page can introduce. Runtime files and assets must match exactly.

## Install the action once

Upload the contents of the supplied **SwitchLauncher** setup folder to the root of **kasobos67/SwitchLauncher**, on **main**. Include the hidden **.github** folder. Commit through GitHub's website. No local Git commands are needed.

The setup includes the workflow, helper, tests and current channel-aware packaging tools. It contains no launcher manifest, runtime source, artwork or sounds, so uploading it does not replace the stable launcher with the test launcher. Keep the existing stable/test feed publication workflows.

## Build a release ZIP

1. Open **Actions → Build stable release from test → Run workflow**.
2. Leave **Use workflow from** set to **main**.
3. Enter the existing test release tag, for example **test-v1.004.003**. It must already be published as a prerelease with its matching **SwitchLauncher-Test-1.004.003.zip** attached.
4. Leave **stable_version** blank to use **1.004.003**, or enter a different three-part numeric version. The chosen stable version must be newer than every already-published stable version.
5. Run it and wait for the green result.
6. At the bottom of the run summary, download **SwitchLauncher-1.004.003-release** from **Artifacts**. Extract that download.

Inside are:

- **SwitchLauncher-1.004.003.zip** — the installable ZIP to attach to the stable release.
- **SwitchLauncher-1.004.003.zip.sha256** — its checksum.
- **promotion.json** — the tested tag, exact source commit, original ZIP checksum and stable ZIP checksum.

GitHub wraps these files in an artifact download ZIP. Upload the **inner SwitchLauncher-1.004.003.zip**, not the artifact wrapper, to Releases.

The action changes the folder/ID from `switch-ui-test` to `switch-ui`, the displayed name to **Switch UI**, the optional version and the permanent feed to **update-feed**. It removes the test-branch installation notice from the bundled README. Other documentation and credits remain. The tested Lua behaviour, host/API requirements, state schema, loading screen, artwork and audio are preserved.

## Publish the stable update

1. Keep `main` up to date with the tested `src`, `assets`, `loading.json` and documentation when promoting source changes. Preserve its stable manifest identity/feed and set its version to the selected stable version. The action itself does not merge or edit branches.
2. Create a new normal GitHub release, for example **v1.004.003**, targeting **main**. Leave **Set as a pre-release** unchecked.
3. Attach the generated installable **SwitchLauncher-1.004.003.zip** and optionally its checksum. Add the release notes, then publish.
4. Wait for the existing **Publish launcher update feed** workflow to succeed. It verifies the stable ZIP and updates the stable feed automatically.

The numeric version may be the same in test and stable: **test-v1.004.003** and **v1.004.003** are separate releases. Do not rename or replace the published test ZIP, change its prerelease flag, or reuse an already-published stable version. Test users remain on the test channel until they select the stable launcher. Stable users receive the new stable update through About as before.

No ProsperoEden host/API change is required. The minimum required host remains **1.004.000**.

## If the action stops

- **Test release not found:** check the tag and publish the prerelease first.
- **Matching ZIP missing:** attach the named installable test ZIP to that test release.
- **Stable version must be newer:** choose an unused stable version higher than the current stable release. You can build an older tested package under a newer stable version.
- **Published test ZIP does not match its tagged source:** the release was tagged before/after different source was uploaded, or its attached ZIP came from different source. Publish a new test tag and matching ZIP, test that version, then promote it. Moving the test branch does not repair an existing tag.
- **Checksum/size mismatch:** the download and GitHub asset metadata disagree. Retry after checking that the release asset finished uploading; do not bypass verification.

This workflow uses read-only repository permission and GET requests. It never creates a release, changes a tag, uploads an asset, merges source, updates a feed or sends an update to users. Download artifacts within 30 days, or run it again before the stable version is published.
