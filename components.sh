#!/usr/bin/env bash
# components.sh
#
# Purpose: Rebuild the AAGL components fork as upstream plus a wine-dwproton-touch group
#
# The launchers hard-reset their local index to the server on every sync, so the fork
# must always be a full index: upstream main with one extra commit on top.
# Env: FORK_SYNC_TOKEN (contents write on the components fork), GH_TOKEN (release reads)
set -Eeuo pipefail
shopt -s inherit_errexit

readonly UPSTREAM=https://github.com/an-anime-team/components.git
readonly FORK_OWNER=popcat19
readonly FORK="https://github.com/${FORK_OWNER}/components.git"
readonly RELEASES_REPO="${FORK_OWNER}/dwproton"
readonly GROUP=wine-dwproton-touch

log() { printf '→ %s\n' "$*"; }

auth_header=$(printf 'x-access-token:%s' "$FORK_SYNC_TOKEN" | base64 -w0)
echo "::add-mask::${auth_header}"
gitauth() { git -c "http.https://github.com/.extraheader=AUTHORIZATION: basic ${auth_header}" "$@"; }

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

# Newest first, matching upstream group files.
builds=$(gh release list -R "$RELEASES_REPO" --limit 100 --json tagName \
  --jq ".[].tagName | select(startswith(\"${GROUP}-\"))" |
  sed "s/^${GROUP}-//" | sort -Vr |
  jq -R -s --arg owner "$FORK_OWNER" --arg group "$GROUP" '
    split("\n") | map(select(length > 0)) | map({
      name: "\($group)-wow64-\(.)",
      title: "wine-dwproton-touch \(.)",
      uri: "https://github.com/\($owner)/dwproton/releases/download/\($group)-\(.)/\($group)-wow64-\(.)-x86_64.tar.xz",
      files: { wine: "bin/wine", wine64: "bin/wine", wineserver: "bin/wineserver", wineboot: "bin/wineboot" }
    })')

if [[ $(jq length <<<"$builds") == 0 ]]; then
  log "no ${GROUP} releases yet; leaving fork untouched"
  exit 0
fi

git clone -q "$UPSTREAM" "$work/components"
cd "$work/components"
git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"

jq --arg group "$GROUP" '
  .wine |= ([{ name: $group, title: "wine-dwproton-touch" }] + map(select(.name != $group)))
' components.json >components.json.tmp
mv components.json.tmp components.json
jq . <<<"$builds" >"wine/${GROUP}.json"
git add components.json "wine/${GROUP}.json"
git commit -q -m "Added ${GROUP} $(jq -r '.[0].title | sub("^wine-dwproton-touch "; "")' <<<"$builds")"

new_tree=$(git rev-parse 'HEAD^{tree}')
upstream_head=$(git rev-parse HEAD~1)
current=$(git ls-remote "$FORK" refs/heads/main | cut -f1)
if [[ -n $current ]] && gitauth fetch -q "$FORK" main 2>/dev/null &&
    [[ $(git rev-parse 'FETCH_HEAD^{tree}') == "$new_tree" ]] &&
    [[ $(git rev-parse FETCH_HEAD~1) == "$upstream_head" ]]; then
  log "fork already matches upstream ${upstream_head:0:8} plus ${GROUP}"
  exit 0
fi

gitauth push -q --force "$FORK" HEAD:refs/heads/main
log "pushed components fork: upstream ${upstream_head:0:8} plus $(jq length <<<"$builds") ${GROUP} build(s)"
