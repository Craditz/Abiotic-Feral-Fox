# Validation and limits

## 0.16.5

This update addresses the 0.16.4 frame rate regression in gameplay and Customization. The shared resolver uses Unreal's native path lookup on cache misses. Repeat lookups use a bounded cache of weak object references. The cooked containers and protocol 3 are carried forward byte for byte. The owner requested that testing be skipped, so frame rate and crash behavior remain unverified in game.

## 0.16.4

The protocol 3 Blueprint was compiled and cooked. The Lua and cooked asset files in the GitHub packages match the local 0.16.4 candidate. The candidate replaces the object lookup path implicated in the UE4SS crash and adds host-controlled Fox collision in multiplayer. The owner requested that testing be skipped. Crash behavior, multiplayer collision and updater 1.0.1 remain untested.

## 0.16.3

The public core retains 0.16.2 behavior except version labels and graceful detection of optional existing local sounds. All 554 non-audio cooked assets retain their exact 0.16.2 cooked-file hashes. All 41 SoundWave assets and their associated files are excluded. The core uses a different IoStore container ID and a higher numbered patch filename so the prior base pack can remain for its local sounds. UE 5.4 mounting code applies that numbered priority to both pak and IoStore mounting. This establishes the intended mount order from engine source, not native game acceptance of the new two-container arrangement.

Prior 0.16.2 checks: isolated Unreal server plus three clients passed owned RPC, private identity isolation, late join, mixed species/appearance changes and state-actor replacement under delay and packet loss. That replacement was not a real Steam reconnect. Actual Abiotic host and one-account peer-renderer-adapter checks through Docker verified facing, hidden packs and immediate inherited native mesh translation. They did not test a second real account.

The updater is checked in disposable folders for installation, preservation of existing config/profile/base-sound files and other mods, invalid/tampered ZIP rejection, failure rollback, repair and avoiding downgrades. Public voice detection is checked with absent and present optional sound assets. Release contents and uploaded hashes are verified. No new in-game acceptance is claimed for 0.16.3.

Actual two-account visibility, reconnect/travel, the core/base mount arrangement and broader remote action/equipment acceptance remain pending. Existing UE4SS crash paths remain unresolved.
