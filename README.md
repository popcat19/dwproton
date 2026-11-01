# dwproton touch fork

Purpose: Build [DW-Proton](https://dawn.wine/dawn-winery/dwproton) with the upstream Wine pointer API backport until DW-Proton ships it

DW-Proton 11.0 inherits a stub `NtUserGetPointerInfoList` that always fails with `ERROR_CALL_NOT_IMPLEMENTED`. Unity titles (Arknights: Endfield, others using the new input system) call `GetPointerTouchInfo` on every `WM_POINTER` touch message, get the error, and drop the tap. The cursor still moves, so touch looks half-working.

Upstream Wine implemented the API in 11.13 and finished the WoW64 thunks in 11.16. This fork carries those 12 commits on top of DW-Proton releases and publishes two builds:

- `dwproton-<ver>-touch`: full Proton for Steam, tracking the newest dawn-winery release.
- `wine-dwproton-touch-<ver>`: standalone Wine runner for AAGL-family launchers, tracking the version pinned by [NelloKudo/spritz-wine](https://github.com/NelloKudo/spritz-wine/tree/dwproton-builds), whose patches make DW-Proton's Wine run outside Steam.

## Branches

| Repo | Branch | Content |
|---|---|---|
| [wine-dwproton](https://github.com/popcat19/wine-dwproton) | `touch/<ver>` | `dwproton/<ver>` plus the backport |
| [dwproton](https://github.com/popcat19/dwproton) | `touch/<ver>` | `dwproton/<ver>` with the `wine` submodule pointed at the fork, inherited CachyOS workflows removed |
| [spritz-wine](https://github.com/popcat19/spritz-wine) | `dwproton-touch` | NelloKudo's `dwproton-builds` with overridable Wine source, ref and release number |
| [components](https://github.com/popcat19/components) | `main` | an-anime-team index plus a `wine-dwproton-touch` group |
| dwproton | `fork-ci` (default) | This README, `sync.sh`, `components.sh`, workflows |

Upstream branches and tags from the initial mirror stay as-is. CI does not re-mirror them.

## Backport

Upstream Wine commits, in order: `94e5bbeb` `339be36e` `0fd66c4f` `e9f822cb` `f4f35739` `92d70dd5` `a1efd6f1` `d5580bc0` `f2481a20` `2448865d` `564cae8a` `07719eff`.

Adaptations for the 11.0 base:

- `win32syscalls.h` is generated at build time by `tools/make_specfiles`, so its upstream edits are dropped.
- `user_thread_info` lives in the zeroed TEB instead of a heap allocation, so `known_pointers` is initialized lazily.
- `process_pointer_message` keeps Proton's raw-to-virtual `lParam` mapping before recording pointer state.
- Proton's touch-window helpers and `NtUserGetTouchInputInfo` are kept; the old `GetPointerType` and `NtUserGetPointerInfoList` stubs are replaced.
- Test-file hunks are skipped. Proton builds with `--disable-tests`.

## CI

`sync.yml` runs every 6 hours and on demand. `sync.sh` handles both targets independently:

1. Pick the version: newest `dwproton/*` branch for Steam, `patches/wine-commit` from spritz-wine `dwproton-builds` for the runner. Skip a target whose release exists.
2. Skip and open an issue if upstream already contains the real implementation.
3. Reuse the fork's `touch/<ver>` branch, or cherry-pick the newest `touch/*` backport onto `dwproton/<ver>`. On conflict, open an issue and fail. A manually resolved `touch/<ver>` push is picked up on the next run.
4. Steam: point the proton fork's `touch/<ver>` submodule at the Wine branch, then call `build.yml`.
5. Runner: rebase the spritz-wine fork onto NelloKudo's branch if it moved, then call `runner.yml`.

`build.yml` builds in the Steam Runtime SDK container (same steps as upstream's CachyOS GitHub job, x86_64 only). `runner.yml` builds with spritz-wine's container. Both check the binaries for the backport before publishing.

`components.sh` runs after every sync. Launchers hard-reset their index to the server, so it rebuilds the fork as upstream `main` plus one commit adding the `wine-dwproton-touch` group, and only force-pushes when that differs.

Secret `FORK_SYNC_TOKEN`: fine-grained PAT, repository access `popcat19/wine-dwproton`, `popcat19/dwproton`, `popcat19/spritz-wine` and `popcat19/components`, permissions Contents read/write and Workflows read/write.

## Install

Steam, manual: extract `dwproton-<ver>-touch.tar.xz` into `~/.local/share/Steam/compatibilitytools.d/`, restart Steam, and select it per game (Steam properties or the ProtonPlus Games tab). ProtonPlus cannot download this build because its sources are hardcoded.

Steam, NixOS: the `dwproton-touch.nix` home module in [popcat19-nixos-hm](https://github.com/PopCat19/popcat19-nixos-hm) runs `dwproton-touch-update` hourly. It installs the newest release as `DW-Proton Touch Latest` after checking the `.sha512sum`, defers while Steam runs, and leaves ProtonPlus-managed tools alone.

AAGL-family launchers: set `components.servers` in the launcher's `config.json` to `["https://github.com/popcat19/components"]` only. The launcher skips syncing when its local index matches any listed server, so keeping upstream in the list leaves it on upstream. On next start it lists `wine-dwproton-touch` under Wine versions; download and select it there. The NixOS module above sets the server and backs up the original as `config.json.pre-dwproton-touch`.

## Operations

- Manual builds: dispatch `build.yml` (`version`) or `runner.yml` (`version`, existing `touch/<ver>` branch). `sync.sh` skips a target while a manually dispatched run of its workflow is in progress, so the two never race for one release.
- Rebuild: dispatch `sync.yml` with `force`. The release is replaced.
- Conflicts: the sync opens an issue naming the commit and files. Resolve locally, push `touch/<ver>` to the wine fork (or `dwproton-touch` to the spritz fork), then rerun `sync.yml`.
- Token: `FORK_SYNC_TOKEN` expires 2027-11. Syncs fail at the first authenticated fetch once it lapses. Create a new token with the same repositories and permissions and run `gh secret set FORK_SYNC_TOKEN -R popcat19/dwproton`.
- Retirement: when the sync opens "Upstream dwproton <ver> ships the pointer API", switch Steam games back to upstream DW-Proton, restore each launcher's `config.json.pre-dwproton-touch` (or set `components.servers` back to `["https://github.com/an-anime-team/components"]`), disable the module, and archive the four forks.
