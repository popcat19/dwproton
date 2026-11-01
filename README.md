# dwproton touch fork

Purpose: Build [DW-Proton](https://dawn.wine/dawn-winery/dwproton) with the upstream Wine pointer API backport until DW-Proton ships it

DW-Proton 11.0 inherits a stub `NtUserGetPointerInfoList` that always fails with `ERROR_CALL_NOT_IMPLEMENTED`. Unity titles (Arknights: Endfield, others using the new input system) call `GetPointerTouchInfo` on every `WM_POINTER` touch message, get the error, and drop the tap. The cursor still moves, so touch looks half-working.

Upstream Wine implemented the API in 11.13 and finished the WoW64 thunks in 11.16. This fork carries those 12 commits on top of each DW-Proton release.

## Branches

| Repo | Branch | Content |
|---|---|---|
| [wine-dwproton](https://github.com/popcat19/wine-dwproton) | `touch/<ver>` | `dwproton/<ver>` plus the backport |
| [dwproton](https://github.com/popcat19/dwproton) | `touch/<ver>` | `dwproton/<ver>` with the `wine` submodule pointed at the fork, inherited CachyOS workflows removed |
| dwproton | `fork-ci` (default) | This README, `sync.sh`, workflows |

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

`sync.yml` runs every 6 hours and on demand:

1. Find the newest `dwproton/*` branch on dawn.wine. Stop if `dwproton-<ver>-touch` is already released.
2. Stop and open an issue if upstream already contains the real implementation.
3. Cherry-pick the newest `touch/*` backport onto `dwproton/<ver>`. On conflict, open an issue and fail.
4. Push `touch/<ver>` to both forks, then call `build.yml`.

`build.yml` builds in the Steam Runtime SDK container (same steps as upstream's CachyOS GitHub job, x86_64 only) and publishes `dwproton-<ver>-touch.tar.xz` as a release.

Secret `FORK_SYNC_TOKEN`: fine-grained PAT, repository access `popcat19/wine-dwproton` and `popcat19/dwproton`, permissions Contents read/write and Workflows read/write.

## Install

Steam: extract the release tarball into `~/.local/share/Steam/compatibilitytools.d/`, restart Steam, select `dwproton-<ver>-touch` per game.

AAGL-family launchers: the tarball's `files/` directory is a Wine tree. Untested as a launcher runner.
