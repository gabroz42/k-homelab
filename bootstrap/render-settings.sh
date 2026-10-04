#!/usr/bin/env bash
#
# render-settings.sh — write clusters/homelab/cluster-settings.yaml from bootstrap/site.env.
#
# The key list comes from the existing cluster-settings.yaml, so adding a variable to the
# ConfigMap automatically makes it required here. Every key must be set in site.env.
#
#   render-settings.sh            rewrite the file in place
#   render-settings.sh --check    exit 1 if the file differs from what site.env renders

set -euo pipefail

cd "$(dirname "$0")/.."
SETTINGS=clusters/homelab/cluster-settings.yaml
ENV_FILE=${SITE_ENV:-bootstrap/site.env}

[ -f "$ENV_FILE" ] || { echo "missing $ENV_FILE (copy bootstrap/site.env.example)"; exit 1; }
# shellcheck disable=SC1090
source "$ENV_FILE"

mapfile -t KEYS < <(awk '/^data:/{d=1;next} d && /^  [A-Z0-9_]+:/{sub(/^  /,"");sub(/:.*/,"");print}' "$SETTINGS")
[ "${#KEYS[@]}" -gt 0 ] || { echo "no keys found in $SETTINGS"; exit 1; }

render() {
  cat <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: cluster-settings
  namespace: flux-system
data:
EOF
  local k v
  for k in "${KEYS[@]}"; do
    v=${!k-}
    if [[ $v =~ ^[0-9]+$ ]]; then
      printf '  %s: "%s"\n' "$k" "$v"
    else
      printf '  %s: %s\n' "$k" "$v"
    fi
  done
}

missing=()
for k in "${KEYS[@]}"; do
  [ -n "${!k-}" ] || missing+=("$k")
done
if [ "${#missing[@]}" -gt 0 ]; then
  echo "site.env is missing: ${missing[*]}"
  exit 1
fi

if [ "${1:-}" = "--check" ]; then
  if ! diff -u "$SETTINGS" <(render); then
    echo
    echo "$SETTINGS does not match $ENV_FILE. Run bootstrap/render-settings.sh, commit and push."
    exit 1
  fi
  echo "cluster-settings matches site.env"
else
  render > "$SETTINGS"
  echo "wrote $SETTINGS — review, commit and push it before bootstrapping"
fi
