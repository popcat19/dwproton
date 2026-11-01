#!/usr/bin/env bash
# sync.sh
#
# Purpose: Rebase the touch backport onto the latest dwproton release and publish fork branches
#
# Outputs (GITHUB_OUTPUT): build=true|false, version=<11.0-N>
# Env: FORK_SYNC_TOKEN (contents+workflows write on both forks), GH_TOKEN (issues/releases)
#      INPUT_VERSION (optional, e.g. 11.0-16), INPUT_FORCE (true to rebuild an existing release)
set -Eeuo pipefail

readonly UPSTREAM_WINE=https://dawn.wine/dawn-winery/wine-dwproton.git
readonly UPSTREAM_PROTON=https://dawn.wine/dawn-winery/dwproton.git
readonly FORK_OWNER=popcat19
readonly FORK_WINE="https://github.com/${FORK_OWNER}/wine-dwproton.git"
readonly FORK_PROTON="https://github.com/${FORK_OWNER}/dwproton.git"
readonly PROTON_REPO="${FORK_OWNER}/dwproton"
# String introduced by upstream Wine 564cae8a; present means the fix landed upstream.
readonly UPSTREAM_FIX_MARKER='pointer id %d not found'

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

latest_version() {
  git ls-remote --heads "$UPSTREAM_PROTON" 'dwproton/*' |
    sed -n 's|.*refs/heads/dwproton/||p' | sort -V | tail -1
}

latest_touch() {
  git ls-remote --heads "$FORK_WINE" 'touch/*' |
    sed -n 's|.*refs/heads/touch/||p' | sort -V | tail -1
}

out build false

version=${INPUT_VERSION:-$(latest_version)}
[[ $version =~ ^[0-9]+\.[0-9]+-[0-9]+$ ]] || { echo "invalid version: ${version}" >&2; exit 1; }
out version "$version"
tag="dwproton-${version}-touch"
log "target ${version} (${tag})"

if [[ ${INPUT_FORCE:-false} != true ]] && gh release view "$tag" -R "$PROTON_REPO" >/dev/null 2>&1; then
  log "release ${tag} exists; nothing to do"
  exit 0
fi

prev=$(latest_touch)
[[ -n $prev ]] || { echo "no touch/* branch in ${FORK_WINE}" >&2; exit 1; }
log "patch source touch/${prev}"

git config --global user.name "github-actions[bot]"
git config --global user.email "41898282+github-actions[bot]@users.noreply.github.com"
git config --global advice.detachedHead false

# wine: replay the backport onto the new upstream release branch.
git init -q "$work/wine"
cd "$work/wine"
git remote add upstream "$UPSTREAM_WINE"
git remote add fork "$FORK_WINE"
git config remote.upstream.promisor true
git config remote.upstream.partialclonefilter blob:none
git config remote.fork.promisor true
git config remote.fork.partialclonefilter blob:none
git fetch -q --filter=blob:none upstream "+refs/heads/dwproton/*:refs/remotes/upstream/dwproton/*"
gitauth fetch -q --filter=blob:none fork "+refs/heads/touch/*:refs/remotes/fork/touch/*"

if git show "upstream/dwproton/${version}:dlls/win32u/input.c" | grep -Fq "$UPSTREAM_FIX_MARKER"; then
  open_issue "Upstream dwproton ${version} ships the pointer API" \
"\`dwproton/${version}\` in dawn-winery/wine-dwproton contains the upstream \`NtUserGetPointerInfoList\` implementation (marker: \`${UPSTREAM_FIX_MARKER}\`).

The touch backport is no longer needed. Switch to upstream DW-Proton and retire this fork."
  exit 0
fi

base=$(git merge-base "fork/touch/${prev}" "upstream/dwproton/${prev}")
mapfile -t picks < <(git rev-list --reverse --no-merges "${base}..fork/touch/${prev}")
(( ${#picks[@]} > 0 )) || { echo "touch/${prev} has no backport commits" >&2; exit 1; }
log "replaying ${#picks[@]} commits"

git checkout -q -B "touch/${version}" "upstream/dwproton/${version}"
for c in "${picks[@]}"; do
  if ! git cherry-pick --allow-empty --keep-redundant-commits "$c" >/dev/null 2>&1; then
    conflicts=$(git diff --name-only --diff-filter=U | sed 's/^/- /')
    subject=$(git log -1 --format=%s "$c")
    git cherry-pick --abort || true
    open_issue "Backport conflict on dwproton ${version}" \
"Replaying \`touch/${prev}\` onto \`dwproton/${version}\` stopped at:

\`${c:0:11}\` ${subject}

Conflicting files:
${conflicts}

Resolve locally, push \`touch/${version}\` to ${FORK_WINE}, then rerun the sync workflow."
    exit 1
  fi
done
wine_sha=$(git rev-parse HEAD)
gitauth push -q --force fork "HEAD:refs/heads/touch/${version}"
log "pushed wine touch/${version} ${wine_sha:0:11}"

# proton: same release branch with the wine submodule pointed at the fork.
git init -q "$work/proton"
cd "$work/proton"
git remote add upstream "$UPSTREAM_PROTON"
git config remote.upstream.promisor true
git config remote.upstream.partialclonefilter blob:none
git fetch -q --filter=blob:none upstream "+refs/heads/dwproton/${version}:refs/remotes/upstream/dwproton/${version}"
git checkout -q -B "touch/${version}" "upstream/dwproton/${version}"
git config -f .gitmodules submodule.wine.url "$FORK_WINE"
git config -f .gitmodules submodule.wine.branch "touch/${version}"
git update-index --cacheinfo "160000,${wine_sha},wine"
git rm -q -r --ignore-unmatch .github/workflows
git add .gitmodules
git commit -q -m "touch: build wine from ${FORK_OWNER}/wine-dwproton touch/${version}

Backports upstream Wine 11.13-11.16 pointer API (GetPointerType,
GetPointerInfoList, GetPointerTouchInfo*) so Unity titles stop dropping
touchscreen taps. Removes inherited CachyOS GitHub workflows; fork CI
lives on the fork-ci branch."
gitauth push -q --force "$FORK_PROTON" "HEAD:refs/heads/touch/${version}"
log "pushed proton touch/${version}"

out build true
