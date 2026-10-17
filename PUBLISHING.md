# Publish Switch UI Test 1.004.003

## Upload the source

Extract **SwitchLauncher-test-versions-1.004.003-source.zip** and upload the contents of its **SwitchLauncher** folder to the root of the repository's **test-versions** branch. Include the hidden **.github** folder. Do not upload this test source or its test manifest over `main`.

If this is your first channel setup, upload the **main-branch files from the 1.004.002 test-channel setup delivery** to `main` first. That installs the separate test publication workflow and channel-aware publisher on the default branch. The stable ID and feed remain `switch-ui` / `update-feed`; the test ID and feed remain `switch-ui-test` / `test-update-feed`. This release's full source bundle already contains all test workflows and tools.

## Create the prerelease

1. On GitHub, open **SwitchLauncher → Releases → Draft a new release**.
2. Create tag **test-v1.004.003**, with target **test-versions** after uploading the source.
3. Set the title to **Switch UI Test 1.004.003**.
4. Paste the supplied **RELEASE-NOTES.md** into the description.
5. Attach **SwitchLauncher-Test-1.004.003.zip**. Its `.sha256` file is optional. Attach the installable ZIP, not the source bundle or GitHub's generated source archive.
6. Check **Set as a pre-release**. Leave **Set as the latest release** off.
7. Publish, then wait for **Actions → Publish test launcher update feed** to succeed.

The workflow creates or updates this feed automatically:

```text
https://raw.githubusercontent.com/kasobos67/SwitchLauncher/test-update-feed/launcher-updates.json
```

It verifies the archive identity, numeric version, permanent feed, size and SHA-256, then retains older compatible test entries. There is no need to upload a JSON release asset or modify the stable feed. This can be the first published test release; publishing 1.004.002 first is optional.

## Install or update

An installed **Switch UI Test 1.004.002** can receive this release through **About → Check for updates → Update**. New testers install the `switch-ui-test` folder manually once into `/data/prosperoeden/launchers/`, then select **Switch UI Test** in the launcher picker. Stable Switch UI receives no test update.

No host update or API change is required beyond official **ProsperoEden 1.004.000**. Test preferences stay separate from stable; native settings, user profiles, games and saves remain shared.

## Later tests and promotion

For the next test, increase the numeric manifest version, build or download the `Build test launcher` artifact, then publish the matching new `test-v...` prerelease. Uploading a branch change builds a ZIP but does not publish an update by itself. Do not replace an already-published ZIP.

When ready for stable, copy the tested presentation changes to `main` while preserving its stable manifest ID/feed. Build with `--channel stable` and publish a separate normal `v...` release. Do not promote a test ZIP by changing only its GitHub prerelease flag.

See **TESTING.md** for the full channel setup, build and recovery details.
