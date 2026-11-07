# Feral Fox for Abiotic Factor

A fox stole a computer. Now the scientist is a fox.

A feral quadruped player option: first-person gameplay, 28 coats, independent eyes and paws, mouth-held tools, and animations for movement, resting and native actions. Choose Fox during character creation or in the Fox tab in main-menu Customization.

## Download and update

Get downloads from [Releases](https://github.com/Craditz/Abiotic-Feral-Fox/releases). Current releases are **experimental**. No GitHub account is required.

Recommended: download **FeralFox-Updater.zip**, extract its two files beside `AbioticFactor.exe` (Steam > Manage > Browse local files), fully close the game, then double-click **Update-FeralFox.cmd**. It asks before installation, downloads a published version, verifies SHA-256 and individual files, backs up replacements and restores them if installation fails. It installs the tested UE4SS loader when absent. Normally writable Steam libraries need no administrator rights.

**Upgrading from 0.16.3:** replace both updater files with the copy from the 0.16.4 release before running the updater. Version 1.0.1 adds support for the new lookup module.

Run the same file for future updates. In PowerShell, `./FeralFox-Updater.ps1 -CheckOnly` checks without installing; `-Repair` reinstalls the current release. Experimental prereleases are included. It never updates an open game or runs automatically in the background. It installs release assets, never arbitrary branch contents.

Existing config, character selections, host identity, saves and other mods are preserved. Only the FeralFoxPrototype entry is enabled in mods.txt. Replaced files are backed up under `.FeralFoxUpdater/backups`. Linked/junction installation paths are rejected. Keep backups until you have checked the update.

For a manual new installation, extract **FeralFox-0.16.4-with-UE4SS-Windows.zip** into the game folder. It includes default loader, config and mod-list files. Existing installations can use the updater to preserve their settings. The manual **update ZIP** requires UE4SS. All three `FeralFoxCore_2_P` asset files must stay together.

## Existing local sounds

Public downloads contain **no replacement sound assets**. If an earlier private build is installed, its three `FeralFoxAssets_P` files are left untouched and its existing vocals can still be used. The new core pack has higher patch priority for non-audio assets. Keep those old base files if you want existing local sounds; the updater cannot recover them if deleted. No new sounds are required. New installations retain native scientist vocals. Set `fox_voice=false` to keep native vocals even when local sounds are available.

## Multiplayer and characters

Use matching versions on the listen host and every client. Existing worlds remain valid. Network characters have separate choices from standalone characters. For an existing character: load its world once, return to main menu, then Customization > Fox > Character; select the Network entry, choose Fox, Save Changes and reload.

The host controls Fox collision through `small_collision` and `collision_scale` in its config. The default scale is 0.375. The host sends the applied size to clients using protocol 3. Multiplayer collision and the object lookup change in 0.16.4 are untested. This experimental release targets listen hosts with matching modded clients.

## Controls and settings

F7 toggles first person / external inspection. F3 previews animation while stationary in inspection; Shift+F3 previews rest loops. F9/F10 provide keyboard look. F10 also toggles the native HUD. F8 writes a diagnostic report beside main.lua; Steam F12 takes screenshots. Ordinary play needs no test keys.

Edit `AbioticFactor/Binaries/Win64/ue4ss/Mods/FeralFoxPrototype/Scripts/config.lua` with the game closed. Keep `developer_controls=false` in release builds. You can disable inspection separately. Leave tight gaps before changing to Human. Hidden equipment retains its normal effects.

Previously observed UE4SS crashes in native parameter conversion and object lookup after portal travel remain unresolved. Back up important worlds. Mouth contact, effects/reloads and some animation fit remain approximate. See [VALIDATION.md](VALIDATION.md) for the exact verification boundary.

## Credits and source

See [THIRD-PARTY.md](THIRD-PARTY.md) and UE4SS-LICENSE.txt. Original project code has not been assigned an open-source license. Making source visible does not relicense third-party material. This is an unofficial mod, not affiliated with Deep Field Games or UE4SS authors.

`src/Scripts` contains the public Lua runtime; the root PowerShell files are the updater. Cooked Fox containers are release assets rather than Git history. `asset-manifest.json` records their hashes and contents. The full editable art/Unreal workspace is not included. Maintainers package verified containers with `python tools/package-public.py --bundle <container-folder> --loader <prior-verified-clean-bundle.zip> --output <release-folder>`.
