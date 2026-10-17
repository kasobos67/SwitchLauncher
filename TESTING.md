# SwitchLauncher test channel

Switch UI Test uses the existing official ProsperoEden **1.004.000** launcher API. No application rebuild or API change is required. Its first release is **1.004.002**, based on the optimized SwitchLauncher 1.004.002 source. This delivery adds channel packaging and publication, and identifies the test pack in the picker and About page. It does not implement the other UI changes discussed during the review.

## Set up the repository once

The repository stays **kasobos67/SwitchLauncher**. `test-versions` is a development branch in that repository; both stable and test releases appear in its Releases list.

1. Extract `SwitchLauncher-main-branch-files.zip`. Upload the contents of its `SwitchLauncher` folder to the root of **`main`**, preserving `.github/workflows`, `tools`, `tests`, `src`, `assets` and `docs`. Do not upload the enclosing folder or the ZIP itself as repository source.
2. Extract `SwitchLauncher-test-versions-branch-files.zip`. Upload the contents of its `SwitchLauncher` folder to the root of **`test-versions`**. Its manifest already uses the separate test ID and feed. Keep the `main` and `test-versions` manifests on their respective branches.
3. Enable GitHub Actions if the repository asks. The feed jobs request **Contents: write** using the repository's built-in `GITHUB_TOKEN`; no personal token or PS5 credential is needed. Repository or organization policy and branch rules must allow creation and updates of the two feed branches.
4. Keep both workflow definitions on `main` as well as in the tagged source. This makes their manual retry controls available and includes the correct workflow when new release tags are created.
5. Create a release with tag **`test-v1.004.002`**, targeting **`test-versions`**. Attach **`SwitchLauncher-Test-1.004.002.zip`** and optionally its `.sha256` file. Mark it **Set as a pre-release**, leave **Set as the latest release** off, then publish.
6. Wait for **Actions → Publish test launcher update feed** to succeed. It creates or updates `test-update-feed/launcher-updates.json`. Check that its `id` is `switch-ui-test`, and its first entry references the uploaded test ZIP.

The feed URL is permanent:

```text
https://raw.githubusercontent.com/kasobos67/SwitchLauncher/test-update-feed/launcher-updates.json
```

The feed is not a file on the `test-versions` source branch. Do not put it on `main`, change the existing stable feed or attach it as a release asset in place of the workflow. A generated copy is included in this delivery for inspection; the workflow is the normal publisher and creates the feed branch automatically.

GitHub's `release: published` event covers published prereleases. The test job requires a `test-v` tag and the prerelease flag; the stable job requires a `v` tag and a stable release. Each publisher independently verifies the same rules before it writes anything. The workflow checks out the release's tag, so test publication uses the tagged test source. See [GitHub's release event documentation](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows#release).

## Install on PS5 once

1. Close ProsperoEden.
2. Extract the **installable** `SwitchLauncher-Test-1.004.002.zip`.
3. Copy its `switch-ui-test` folder into `/data/prosperoeden/launchers/`. The file must be `/data/prosperoeden/launchers/switch-ui-test/manifest.json`.
4. Open ProsperoEden and select **Switch UI Test** in **Settings → Appearance → Launcher**. From an existing Switch UI pack, the picker is under **System Settings → Themes → Launcher**.
5. Open About. It should show **Switch UI Test** and version **1.004.002**. After its first release has been published and the feed workflow has succeeded, checking for updates should report that it is current.

Leave the stable `switch-ui` folder in place. Select **Switch UI** in the same picker to return to stable. The test pack has separate appearance/avatar preferences and diagnostics at `/data/prosperoeden/config/launcher-state/switch-ui-test.json`; the original stable state file is preserved. Native settings, native profiles, games and saves are still shared between the two packs.

No menu toggle can install the first test pack through the existing API. After this one manual installation, later compatible test versions install through **About → Check for updates → Update** using the normal native verification and recovery path.

## Publish another test

1. Make your changes on `test-versions`. Increase the three-part numeric `version` in that branch's `manifest.json`, for example **1.004.003**. Keep the test ID, permanent feed, API and state schema unless intentionally planning a migration.
2. Upload your changed source to `test-versions`. **Actions → Build test launcher** runs its checks and produces a downloadable artifact containing the installable ZIP and checksum. A branch upload builds the pack but does not publish an update to users.
3. Download that artifact from the successful run and extract it. Alternatively build locally with Python 3.10 or newer:

   ```sh
   python tools/build_release.py --channel test --tag test-v1.004.003
   ```

4. Create prerelease **`test-v1.004.003`**, targeting the tested `test-versions` commit. Attach **`SwitchLauncher-Test-1.004.003.zip`** before publishing. Its tag and packaged manifest must contain the same numeric version.
5. Wait for **Publish test launcher update feed**. Test users can then check in About and confirm the update. The normal boot/game-return checks also use this test feed.

Use a new version and tag for every published test. Do not replace an existing version's ZIP. The publisher rejects replacements and preserves earlier compatible entries, up to the newest 64 releases per channel. Avoid enormous placeholder versions: the host only offers versions newer than the installed one.

To retry an existing publication, use **Publish test launcher update feed → Run workflow** from `main`, enter the existing `test-v...` tag, then run it. Retrying an unchanged release is safe. Upload the missing asset or correct the prerelease flag first when that caused the failure.

## Promote tested changes to stable

1. Copy the tested `src`, `assets` and any needed supporting changes from `test-versions` to `main`. Keep `main`'s stable manifest identity: **`switch-ui`**, name **Switch UI**, feed **`update-feed`**. Do not replace it with the test manifest.
2. Set a numeric version greater than the latest published **stable** version. The two channels can use the same numeric version because their pack IDs and feeds are separate.
3. Build with `python tools/build_release.py --channel stable`, or use your existing stable packaging process with the updated tools.
4. Publish a normal stable **`v<version>`** release with **`SwitchLauncher-<version>.zip`** attached. The stable publisher updates only `update-feed`; the test publisher does not run for this release.

Do not turn a published test prerelease into a stable release by unchecking its flag. Promotion uses a new stable tag and a stable-built ZIP. Test users remain on the test pack until they select the stable pack; promotion does not silently change their channel.

## Local checks

```sh
python -m unittest discover -s tests -v
```

The suite covers both archive identities and feeds, prerelease separation, channel-specific tags, unchanged runtime compatibility requirements, immutable releases, concurrent feed updates and repeat publication. Existing Lua refresh-policy and scrolling checks remain available as described in README.md.
