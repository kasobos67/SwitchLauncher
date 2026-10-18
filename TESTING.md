# Switch UI Test 1.005.000

Install official **ProsperoEden 1.005.000** first. Extract **SwitchLauncher-Test-1.005.000.zip** and copy its `switch-ui-test` folder to `/data/prosperoeden/launchers/` while the application is closed. Existing testers replace that folder only; preserve the launcher-state JSON and other user data.

Select **Switch UI Test** in the built-in launcher's **Settings > Appearance > Launcher**, or from Switch UI's **System Settings > Themes > Launcher**. Stable Switch UI remains a separate pack with its own appearance/avatar state. Native preferences, games and saves remain shared.

## Check on PS5

- HOME, library, profiles, light/dark appearance and saved avatars still behave as before, including after restarting the app.
- Global **Performance > Speed limit** shows five steps. A game's Performance settings can choose an override or follow Settings.
- A game's **Mods** lists patches/replacement files. **Cheats** lists its cheats with an independent **All cheats** switch. Existing enabled cheats should stay enabled.
- **System > Update notices** follows the native preference. With it off, an available application update stays visible in About and can be opened with Triangle.
- **Video > Frame gen method** explains how to open the built-in launcher and choose MihawkGen or Lossless Scaling. Return through **Settings > Appearance > Launcher > Switch UI Test**. The remaining frame generation controls use that saved native method.
- Check folder-organized games, their updates/DLC and a download, using the host's existing services. A game's local reshade presets should appear after the shared presets in its Video settings.
- Launcher updating still uses the permanent **test-update-feed** address and does not deliver this prerelease to stable users.

## Publish and build

Follow **PUBLISHING.md** to publish **test-v1.005.000** and attach the installable test ZIP. The matching source tag matters: the stable promotion action verifies it against the published test ZIP.

The manual/local pack command is:

```sh
python tools/build_release.py --channel test --tag test-v1.005.000
```

**Build test launcher** runs the repository checks and saves a ZIP/checksum artifact. It does not publish a release or alter a feed.

Local checks:

```sh
python -m unittest discover -s tests -v
lua5.4 tests/host_1005000.lua
lua5.4 tests/ui_polish.lua
lua5.4 tests/refresh_policy.lua
lua5.4 tests/scroll_motion.lua
```

Keep the test ID `switch-ui-test`, name `Switch UI Test` and permanent feed `https://raw.githubusercontent.com/kasobos67/SwitchLauncher/test-update-feed/launcher-updates.json`. Promotion creates a separate stable ZIP with `switch-ui` and `update-feed`. Do not rename a test ZIP into a stable one.
