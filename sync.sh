#!/usr/bin/env bash
# sync.sh
#
# Purpose: Rebase the touch backport onto upstream releases and publish fork branches
#
# Targets:
#   proton  newest dawn-winery dwproton/* release (Steam build)
#   runner  wine-dwproton version pinned by NelloKudo/spritz-wine dwproton-builds (AAGL runner)
#
# Outputs (GITHUB_OUTPUT): proton_build, proton_version, runner_build, runner_version
# Env: FORK_SYNC_TOKEN (contents+workflows write on the forks), GH_TOKEN (issues/releases)
#      INPUT_VERSION, INPUT_RUNNER_VERSION (optional overrides), INPUT_FORCE (true to rebuild)
set -Eeuo pipefail
shopt -s inherit_errexit

readonly UPSTREAM_WINE=https://dawn.wine/dawn-winery/wine-dwproton.git
readonly UPSTREAM_PROTON=https://dawn.wine/dawn-winery/dwproton.git
readonly UPSTREAM_SPRITZ=https://github.com/NelloKudo/spritz-wine.git
readonly UPSTREAM_SPRITZ_BRANCH=dwproton-builds
readonly FORK_OWNER=popcat19
readonly FORK_WINE="https://github.com/${FORK_OWNER}/wine-dwproton.git"
readonly FORK_PROTON="https://github.com/${FORK_OWNER}/dwproton.git"
readonly FORK_SPRITZ="https://github.com/${FORK_OWNER}/spritz-wine.git"
readonly FORK_SPRITZ_BRANCH=dwproton-touch
readonly PROTON_REPO="${FORK_OWNER}/dwproton"
# String introduced by upstream Wine 564cae8a; present means the fix landed upstream.
readonly UPSTREAM_FIX_MARKER='pointer id %d not found'
readonly VERSION_RE='^[0-9]+\.[0-9]+-[0-9]+$'

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

out() { printf '%s=%s\n' "$1" "$2" >>"${GITHUB_OUTPUT:-/dev/null}"; }
log() { printf '→ %s\n' "$*"; }

# Basic auth header keeps the token out of remote URLs and error output.
auth_header=$(printf 'x-access-token:%s' "$FORK_SYNC_TOKEN" | base64 -w0)
echo "::add-mask::${auth_header}"
gitauth() { git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth_header}" "$@"; }

open_issue() {
  local title=$1 body=$2
  if gh issue list -R "$PROTON_REPO" --state open --search "\"${title}\" in:title" --json title \
      --jq '.[].title' | grep -Fxq "$title"; then
    log "issue already open: ${title}"
  else
    gh issue create -R "$PROTON_REPO" --title "$title" --body "$body" >/dev/null
    log "opened issue: ${title}"
  fi
}

# A manually dispatched build still running would race a new one for the same release.
build_running() {
  [[ -n $(gh run list -R "$PROTON_REPO" --workflow "$1" --event workflow_dispatch \
    --json status --jq '.[] | select(.status != "completed") | .status' | head -1) ]]
}

release_exists() {
  [[ ${INPUT_FORCE:-false} != true ]] && gh release view "$1" -R "$PROTON_REPO" >/dev/null 2>&1
}

partial_remote() {
  git remote add "$1" "$2"
  git config "remote.$1.promisor" true
  git config "remote.$1.partialclonefilter" blob:none
}

# Prints the fork's touch/<ver> sha, creating it from the newest touch branch when missing.
ensure_wine_branch() {
  local ver=$1 prev base c conflicts subject
  local -a picks

  if [[ -n $(git ls-remote --heads fork "touch/${ver}") ]]; then
    git rev-parse "fork/touch/${ver}"
    return
  fi

  prev=$(git for-each-ref --format='%(refname:lstrip=4)' 'refs/remotes/fork/touch/' | sort -V | tail -1)
  [[ -n $prev ]] || { echo "no touch/* branch in ${FORK_WINE}" >&2; return 1; }
  base=$(git merge-base "fork/touch/${prev}" "upstream/dwproton/${prev}")
  mapfile -t picks < <(git rev-list --reverse --no-merges "${base}..fork/touch/${prev}")
  (( ${#picks[@]} > 0 )) || { echo "touch/${prev} has no backport commits" >&2; return 1; }
  log "replaying ${#picks[@]} commits from touch/${prev} onto dwproton/${ver}" >&2

  git checkout -q -B "touch/${ver}" "upstream/dwproton/${ver}"
  for c in "${picks[@]}"; do
    if ! git cherry-pick --allow-empty --keep-redundant-commits "$c" >/dev/null 2>&1; then
      conflicts=$(git diff --name-only --diff-filter=U | sed 's/^/- /')
      subject=$(git log -1 --format=%s "$c")
      git cherry-pick --abort || true
      open_issue "Backport conflict on dwproton ${ver}" \
"Replaying \`touch/${prev}\` onto \`dwproton/${ver}\` stopped at:

\`${c:0:11}\` ${subject}

Conflicting files:
${conflicts}

Resolve locally, push \`touch/${ver}\` to ${FORK_WINE}, then rerun the sync workflow." >&2
      return 1
    fi
  done
  gitauth push -q --force fork "HEAD:refs/heads/touch/${ver}" >&2
  log "pushed wine touch/${ver}" >&2
  git rev-parse HEAD
}

# True when upstream dwproton/<ver> already carries the real implementation.
upstream_fixed() {
  local ver=$1
  git show "upstream/dwproton/${ver}:dlls/win32u/input.c" | grep -Fq "$UPSTREAM_FIX_MARKER" || return 1
  open_issue "Upstream dwproton ${ver} ships the pointer API" \
"\`dwproton/${ver}\` in dawn-winery/wine-dwproton contains the upstream \`NtUserGetPointerInfoList\` implementation (marker: \`${UPSTREAM_FIX_MARKER}\`).

The touch backport is no longer needed. Switch to upstream DW-Proton and retire this fork."
}

ensure_proton_branch() {
  local ver=$1 wine_sha=$2 current
  current=$(gh api "repos/${PROTON_REPO}/contents/wine?ref=touch/${ver}" --jq .sha 2>/dev/null || true)
  if [[ $current == "$wine_sha" ]]; then
    log "proton touch/${ver} already points at ${wine_sha:0:11}"
    return
  fi

  rm -rf "$work/proton"
  git init -q "$work/proton"
  (
    cd "$work/proton"
    partial_remote upstream "$UPSTREAM_PROTON"
    git fetch -q --filter=blob:none upstream "+refs/heads/dwproton/${ver}:refs/remotes/upstream/dwproton/${ver}"
    git checkout -q -B "touch/${ver}" "upstream/dwproton/${ver}"
    git config -f .gitmodules submodule.wine.url "$FORK_WINE"
    git config -f .gitmodules submodule.wine.branch "touch/${ver}"
    git update-index --cacheinfo "160000,${wine_sha},wine"
    git rm -q -r --ignore-unmatch .github/workflows
    git add .gitmodules
    git commit -q -m "touch: build wine from ${FORK_OWNER}/wine-dwproton touch/${ver}

Backports upstream Wine 11.13-11.16 pointer API (GetPointerType,
GetPointerInfoList, GetPointerTouchInfo*) so Unity titles stop dropping
touchscreen taps. Removes inherited CachyOS GitHub workflows; fork CI
lives on the fork-ci branch."
    gitauth push -q --force "$FORK_PROTON" "HEAD:refs/heads/touch/${ver}"
  )
  log "pushed proton touch/${ver}"
}

# Replays the fork's spritz commits onto NelloKudo's branch when upstream moved.
sync_spritz() {
  local dir="$work/spritz" upstream_sha fork_sha base c
  local -a picks
  git init -q "$dir"
  git -C "$dir" fetch -q "$UPSTREAM_SPRITZ" "$UPSTREAM_SPRITZ_BRANCH"
  upstream_sha=$(git -C "$dir" rev-parse FETCH_HEAD)
  git -C "$dir" fetch -q "$FORK_SPRITZ" "$FORK_SPRITZ_BRANCH"
  fork_sha=$(git -C "$dir" rev-parse FETCH_HEAD)
  if git -C "$dir" merge-base --is-ancestor "$upstream_sha" "$fork_sha"; then
    log "spritz ${FORK_SPRITZ_BRANCH} already on upstream ${upstream_sha:0:8}"
    return
  fi
  base=$(git -C "$dir" merge-base "$upstream_sha" "$fork_sha")
  mapfile -t picks < <(git -C "$dir" rev-list --reverse --no-merges "${base}..${fork_sha}")
  git -C "$dir" checkout -q -B "$FORK_SPRITZ_BRANCH" "$upstream_sha"
  for c in "${picks[@]}"; do
    if ! git -C "$dir" cherry-pick --allow-empty "$c" >/dev/null 2>&1; then
      git -C "$dir" cherry-pick --abort || true
      open_issue "spritz-wine rebase conflict" \
"Replaying \`${FORK_SPRITZ_BRANCH}\` onto NelloKudo/spritz-wine \`${UPSTREAM_SPRITZ_BRANCH}\` (\`${upstream_sha:0:8}\`) conflicted at \`${c:0:8}\` $(git -C "$dir" log -1 --format=%s "$c").

Resolve locally and push \`${FORK_SPRITZ_BRANCH}\` to ${FORK_SPRITZ}."
      return 1
    fi
  done
  gitauth -C "$dir" push -q --force "$FORK_SPRITZ" "HEAD:refs/heads/${FORK_SPRITZ_BRANCH}"
  log "rebased spritz ${FORK_SPRITZ_BRANCH} onto ${upstream_sha:0:8}"
}

target_proton() {
  local wine_sha
  if build_running build.yml; then
    log "manual build.yml run in progress; skipping proton"
    return
  fi
  if release_exists "dwproton-${proton_ver}-touch"; then
    log "release dwproton-${proton_ver}-touch exists"
    return
  fi
  if upstream_fixed "$proton_ver"; then
    log "upstream ${proton_ver} already fixed; skipping proton"
    return
  fi
  wine_sha=$(ensure_wine_branch "$proton_ver")
  ensure_proton_branch "$proton_ver" "$wine_sha"
  touch "$work/proton_build"
}

target_runner() {
  if build_running runner.yml; then
    log "manual runner.yml run in progress; skipping runner"
    return
  fi
  if release_exists "wine-dwproton-touch-${runner_ver}"; then
    log "release wine-dwproton-touch-${runner_ver} exists"
    return
  fi
  if upstream_fixed "$runner_ver"; then
    log "upstream ${runner_ver} already fixed; skipping runner"
    return
  fi
  ensure_wine_branch "$runner_ver" >/dev/null
  sync_spritz
  touch "$work/runner_build"
}

git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config --global advice.detachedHead false

proton_ver=${INPUT_VERSION:-$(git ls-remote --heads "$UPSTREAM_PROTON" 'dwproton/*' |
  sed -n 's|.*refs/heads/dwproton/||p' | sort -V | tail -1)}
runner_ver=${INPUT_RUNNER_VERSION:-$(curl -fsSL "https://raw.githubusercontent.com/NelloKudo/spritz-wine/${UPSTREAM_SPRITZ_BRANCH}/patches/wine-commit" |
  sed -n 's/^dwproton-//p')}
[[ $proton_ver =~ $VERSION_RE ]] || { echo "invalid proton version: ${proton_ver}" >&2; exit 1; }
[[ $runner_ver =~ $VERSION_RE ]] || { echo "invalid runner version: ${runner_ver}" >&2; exit 1; }
out proton_version "$proton_ver"
out runner_version "$runner_ver"
log "proton target ${proton_ver}, runner target ${runner_ver}"

git init -q "$work/wine"
cd "$work/wine"
partial_remote upstream "$UPSTREAM_WINE"
partial_remote fork "$FORK_WINE"
git fetch -q --filter=blob:none upstream "+refs/heads/dwproton/*:refs/remotes/upstream/dwproton/*"
gitauth fetch -q --filter=blob:none fork "+refs/heads/touch/*:refs/remotes/fork/touch/*"

# Each target runs in its own subshell so one failure does not skip the other.
# `if (...)` would disable errexit inside the subshell, so check $? afterwards.
# shellcheck disable=SC2181
{
  status=0
  set +e
  (set -e; target_proton)
  (( $? == 0 )) || status=1
  (set -e; cd "$work/wine"; target_runner)
  (( $? == 0 )) || status=1
  set -e
}

out proton_build "$([[ -e $work/proton_build ]] && echo true || echo false)"
out runner_build "$([[ -e $work/runner_build ]] && echo true || echo false)"
exit "$status"
