#!/usr/bin/env bash
#
# bootstrap.sh — build this cluster from scratch on a fresh Ubuntu machine.
#
# Prerequisites (done by hand, see docs/INSTRUCTIONS.md "Bootstrapping a new site"):
#   - a fork of this repo + a GitHub PAT
#   - Bitwarden Secrets Manager org/project/machine token with every key the ExternalSecrets use
#   - Cloudflare zone, DNS API token and tunnels, tokens stored in Bitwarden
#   - bootstrap/site.env filled in, bootstrap/render-settings.sh run, result committed + pushed
#
# Usage: sudo bootstrap/bootstrap.sh [--force]
#
# Idempotent: every step checks before it changes anything, so a failed run can be re-run.
# Refuses to touch a host that already runs workloads unless --force is given.

set -euo pipefail

cd "$(dirname "$0")/.."
REPO_ROOT=$(pwd)
ENV_FILE=${SITE_ENV:-bootstrap/site.env}
FORCE=0
[ "${1:-}" = "--force" ] && FORCE=1

export KUBECONFIG=/etc/rancher/k3s/k3s.yaml
export PATH=/usr/local/bin:$PATH

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
warn() { printf '\033[1;33m    WARN: %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31mERROR: %s\033[0m\n' "$*" >&2; exit 1; }

wait_for() {
  local what=$1 timeout=$2; shift 2
  local start=$SECONDS
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start > timeout )) && die "timed out after ${timeout}s waiting for $what"
    sleep 5
  done
}

step_guard() {
  [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"
  if command -v k3s >/dev/null && [ -f "$KUBECONFIG" ] && [ "$FORCE" -eq 0 ]; then
    local n
    n=$(kubectl get pods -A --no-headers 2>/dev/null | grep -cvE '^(kube-system|flux-system|longhorn-system|external-secrets) ' || true)
    [ "$n" -eq 0 ] || die "k3s already runs $n workload pods here. This script is for new machines; pass --force to continue anyway."
  fi
}

step_preflight() {
  log "Preflight"
  [ -f "$ENV_FILE" ] || die "missing $ENV_FILE (copy bootstrap/site.env.example)"
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  . /etc/os-release
  [ "$ID" = ubuntu ] || warn "tested on Ubuntu only, this is $PRETTY_NAME"
  local v
  for v in K3S_VERSION GITHUB_OWNER GITHUB_REPO GITHUB_BRANCH GITHUB_TOKEN BWS_ACCESS_TOKEN PRIMARY_NODE PRIMARY_NODE_IP; do
    [ -n "${!v-}" ] || die "$v is empty in $ENV_FILE"
  done
  declare -p DISK_MOUNTS >/dev/null 2>&1 || DISK_MOUNTS=()
  declare -p LONGHORN_EXTRA_DISKS >/dev/null 2>&1 || LONGHORN_EXTRA_DISKS=()
  SITE_ENV=$ENV_FILE bootstrap/render-settings.sh --check
  local git=(git -c "safe.directory=$REPO_ROOT")
  if "${git[@]}" fetch -q origin "$GITHUB_BRANCH"; then
    if ! "${git[@]}" diff --quiet "origin/$GITHUB_BRANCH" -- clusters/homelab/cluster-settings.yaml; then
      die "cluster-settings.yaml differs from origin/$GITHUB_BRANCH — commit and push it first, Flux reads git"
    fi
  else
    warn "could not fetch origin/$GITHUB_BRANCH to compare cluster-settings; make sure it is pushed"
  fi
  local h
  for h in https://github.com https://api.bitwarden.com https://get.k3s.io https://raw.githubusercontent.com; do
    curl -sS -o /dev/null --max-time 10 "$h" || die "cannot reach $h"
  done
  info "inputs OK"
}

step_packages() {
  log "Host packages"
  local pkgs=(open-iscsi nfs-common cryptsetup jq curl git hdparm openssl)
  local missing=()
  for p in "${pkgs[@]}"; do dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p"); done
  if [ "${#missing[@]}" -gt 0 ]; then
    apt-get update -q
    DEBIAN_FRONTEND=noninteractive apt-get install -yq "${missing[@]}"
  fi
  systemctl enable --now iscsid >/dev/null
  printf 'iscsi_tcp\ndm_crypt\n' > /etc/modules-load.d/longhorn.conf
  modprobe iscsi_tcp
  modprobe dm_crypt
  info "packages + modules OK"
}

step_multipath() {
  log "multipathd blacklist (Longhorn devices)"
  if ! systemctl list-unit-files multipathd.service >/dev/null 2>&1; then
    info "multipathd not installed, nothing to do"
    return
  fi
  if ! grep -q 'devnode "\^sd\[a-z0-9\]+"' /etc/multipath.conf 2>/dev/null; then
    cat >> /etc/multipath.conf <<'EOF'

blacklist {
    devnode "^sd[a-z0-9]+"
}
EOF
    systemctl restart multipathd
    multipath -F || true
    info "blacklist added"
  else
    info "already blacklisted"
  fi
}

step_resolv() {
  log "Host DNS"
  if grep -q '100\.100\.100\.100' /etc/resolv.conf 2>/dev/null; then
    chattr -i /etc/resolv.conf 2>/dev/null || true
    rm -f /etc/resolv.conf
    printf 'nameserver 1.1.1.1\nnameserver 1.0.0.1\n' > /etc/resolv.conf
    chattr +i /etc/resolv.conf
    warn "replaced Tailscale MagicDNS resolv.conf; add 'nameserver $ADGUARD_IP' first once AdGuard runs (chattr -i, edit, chattr +i)"
  else
    info "resolv.conf has no MagicDNS upstream, left alone"
  fi
}

traverse_parents() {
  local d=$1
  while [ "$d" != / ] && [ -n "$d" ]; do
    d=$(dirname "$d")
    [ -d "$d" ] && chmod o+x "$d"
  done
}

step_disks() {
  log "Disks"
  local entry dev mnt fs opts
  for entry in "${DISK_MOUNTS[@]}"; do
    read -r dev mnt fs opts <<<"$entry"
    [[ $opts == *nofail* ]] || opts="$opts,nofail"
    mkdir -p "$mnt"
    if ! awk -v m="$mnt" '$1 !~ /^#/ && $2 == m {f=1} END {exit !f}' /etc/fstab; then
      local pass=0
      [[ $fs == ext* || $fs == xfs ]] && pass=2
      printf '%s %s %s %s 0 %s\n' "$dev" "$mnt" "$fs" "$opts" "$pass" >> /etc/fstab
      info "fstab += $mnt"
    fi
  done
  systemctl daemon-reload
  mount -a
  for entry in "${DISK_MOUNTS[@]}"; do
    read -r dev mnt fs opts <<<"$entry"
    mountpoint -q "$mnt" || die "$mnt is not mounted after mount -a"
    traverse_parents "$mnt/x"
  done
  traverse_parents "$MEDIA_PATH/x"
  traverse_parents "$MUSIC_PATH/x"

  if [ -n "${BACKUP_DISK_SERIAL:-}" ]; then
    printf 'ACTION=="add|change", KERNEL=="sd[a-z]", ENV{ID_SERIAL_SHORT}=="%s", RUN+="/sbin/hdparm -S %s /dev/%%k"\n' \
      "$BACKUP_DISK_SERIAL" "${HDPARM_SPINDOWN:-180}" > /etc/udev/rules.d/69-hdd-spindown.rules
    udevadm control --reload
    udevadm trigger --subsystem-match=block --action=change
    info "hdparm spin-down rule for $BACKUP_DISK_SERIAL"
  fi
}

step_hostpaths() {
  log "hostPath directories (uid 1000)"
  local d
  for d in "$BACKUP_PATH/restic" "$MEDIA_PATH" "$MUSIC_PATH" /opt/navidrome /opt/lidarr \
           /var/lib/sonarr /var/lib/radarr /var/lib/prowlarr /var/lib/qbittorrent \
           /var/lib/jellyseerr /var/lib/dispatcharr /var/lib/tvheadend; do
    if [ ! -d "$d" ]; then
      mkdir -p "$d"
      chown 1000:1000 "$d" 2>/dev/null || warn "could not chown $d (non-POSIX filesystem?)"
      info "created $d"
    fi
  done
}

step_k3s() {
  log "k3s $K3S_VERSION"
  mkdir -p /etc/rancher/k3s
  cat > /etc/rancher/k3s/config.yaml <<EOF
node-name: $PRIMARY_NODE
node-ip: $PRIMARY_NODE_IP
advertise-address: $PRIMARY_NODE_IP
tls-san:
  - $PRIMARY_NODE_IP
disable:
  - servicelb
kubelet-arg:
  - max-pods=150
EOF
  if [ "$(k3s --version 2>/dev/null | awk 'NR==1{print $3}')" != "$K3S_VERSION" ]; then
    curl -sfL https://get.k3s.io | INSTALL_K3S_VERSION="$K3S_VERSION" sh -
  else
    info "already installed"
  fi
  wait_for "node $PRIMARY_NODE" 300 kubectl get node "$PRIMARY_NODE"
  kubectl wait --for=condition=Ready "node/$PRIMARY_NODE" --timeout=300s
  if [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ]; then
    local home
    home=$(getent passwd "$SUDO_USER" | cut -d: -f6)
    mkdir -p "$home/.kube"
    install -m 600 -o "$SUDO_USER" /etc/rancher/k3s/k3s.yaml "$home/.kube/config"
    info "kubeconfig copied to $home/.kube/config"
  fi
}

step_seeds() {
  log "Pre-Flux seeds"
  local ns
  for ns in flux-system external-secrets; do
    kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  done
  kubectl apply -f clusters/homelab/cluster-settings.yaml
  kubectl -n external-secrets create secret generic bitwarden-access-token \
    --from-literal=token="$BWS_ACCESS_TOKEN" --dry-run=client -o yaml | kubectl apply -f -
  if ! kubectl -n external-secrets get secret bitwarden-sdk-server-tls >/dev/null 2>&1; then
    bash scripts/generate-bitwarden-tls.sh
  else
    info "bitwarden-sdk-server TLS already present"
  fi
}

step_longhorn() {
  local ver
  ver=$(tr -d '[:space:]' < bootstrap/longhorn/VERSION)
  log "Longhorn $ver"
  local cur
  cur=$(kubectl -n longhorn-system get ds longhorn-manager -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
  if [ -z "$cur" ]; then
    kubectl apply -f "https://raw.githubusercontent.com/longhorn/longhorn/$ver/deploy/longhorn.yaml"
  elif [[ $cur != *":$ver" ]]; then
    warn "Longhorn already installed as $cur, not $ver — upgrades are manual and stepwise, leaving it"
  fi
  kubectl -n longhorn-system rollout status ds/longhorn-manager --timeout=600s
  wait_for "Longhorn node CR" 300 kubectl -n longhorn-system get "nodes.longhorn.io/$PRIMARY_NODE"
  wait_for "Longhorn settings CRD" 120 kubectl -n longhorn-system get settings.longhorn.io deleting-confirmation-flag
  kubectl apply --server-side --force-conflicts -f bootstrap/longhorn/settings.yaml

  local node_json patch entry name path tags have_disk1=0
  node_json=$(kubectl -n longhorn-system get "nodes.longhorn.io/$PRIMARY_NODE" -o json)
  patch='{}'
  for entry in "${LONGHORN_EXTRA_DISKS[@]}"; do
    read -r name path tags <<<"$entry"
    mountpoint -q "$path" || die "Longhorn disk $name: $path is not a mountpoint"
    [[ ",$tags," == *,disk-1,* ]] && have_disk1=1
    patch=$(jq --arg n "$name" --arg p "$path" --arg t "$tags" \
      '.spec.disks[$n] = {path: $p, allowScheduling: true, evictionRequested: false, storageReserved: 0, diskType: "filesystem", tags: ($t | split(",") | map(select(length > 0)))}' <<<"$patch")
  done
  if [ "$have_disk1" -eq 0 ]; then
    local def
    def=$(jq -r '.spec.disks | to_entries[] | select(.value.path | startswith("/var/lib/longhorn")) | .key' <<<"$node_json" | head -1)
    [ -n "$def" ] || die "no default Longhorn disk found to tag disk-1"
    patch=$(jq --arg d "$def" --argjson cur "$(jq --arg d "$def" '.spec.disks[$d]' <<<"$node_json")" \
      '.spec.disks[$d] = ($cur | .tags = ((.tags // []) + ["disk-1"] | unique))' <<<"$patch")
    info "no extra disk tagged disk-1: tagging the default disk ($def) for immich-library"
  fi
  if [ "$patch" != '{}' ]; then
    kubectl -n longhorn-system patch "nodes.longhorn.io/$PRIMARY_NODE" --type merge -p "$patch"
  fi

  if [ "$(kubectl get pvc -A -o jsonpath='{.items[?(@.spec.storageClassName=="longhorn")].metadata.name}')" = "" ]; then
    kubectl -n longhorn-system get cm longhorn-storageclass -o json \
      | jq '.data["storageclass.yaml"] |= sub("numberOfReplicas: \"[0-9]+\""; "numberOfReplicas: \"1\"")' \
      | kubectl apply -f - >/dev/null
    info "default longhorn StorageClass set to 1 replica"
  fi
}

flux_version() {
  sed -n 's/^# Flux Version: v//p' clusters/homelab/flux-system/gotk-components.yaml
}

step_flux() {
  local ver
  ver=$(flux_version)
  log "Flux v$ver"
  if [ "$(flux version --client 2>/dev/null | awk '{print $2}')" != "v$ver" ]; then
    curl -fsSL https://fluxcd.io/install.sh | FLUX_VERSION="$ver" bash
  fi
  GITHUB_TOKEN=$GITHUB_TOKEN flux bootstrap github \
    --owner="$GITHUB_OWNER" \
    --repository="$GITHUB_REPO" \
    --branch="$GITHUB_BRANCH" \
    --path=clusters/homelab \
    --personal \
    --components-extra=image-reflector-controller,image-automation-controller

  local ks
  for ks in infrastructure-configs infrastructure-controllers apps external-secrets-config metallb-config cert-manager-config prometheus; do
    info "waiting for Kustomization $ks"
    wait_for "Kustomization $ks to exist" 600 kubectl -n flux-system get "kustomization/$ks"
    kubectl -n flux-system wait --for=condition=Ready "kustomization/$ks" --timeout=20m \
      || warn "$ks not Ready yet — check 'flux get ks -A'"
  done
}

step_report() {
  log "Status"
  flux get kustomizations -A || true
  kubectl get pods -A --field-selector=status.phase!=Running,status.phase!=Succeeded || true
  cat <<EOF

Remaining manual steps (state lives in app databases or external services):
  1. GitHub webhook: 'task webhook-url', add it to the repo with the HMAC from
     Bitwarden flux-system/github-webhook-token/token.
  2. AdGuard: finish the setup wizard at http://$ADGUARD_IP:3000, then add DNS rewrites
       *.$LOCAL_DOMAIN       -> $TRAEFIK_IP
       authentik.$PUBLIC_DOMAIN -> $TRAEFIK_IP   (only after 'kubectl -n authentik get certificate' is Ready)
     and point the router's DHCP DNS at $ADGUARD_IP.
  3. Host DNS: once AdGuard answers, put 'nameserver $ADGUARD_IP' first in /etc/resolv.conf.
  4. Authentik: create the admin, providers/applications and redirect URIs for
     Grafana, Immich, Nextcloud and the forward-auth outpost.
  5. Apps for hardware this site lacks (UPS: nut-exporter, fan control: pankha,
     ESP32: centralino, DVB tuner: tvheadend) — remove them from apps/kustomization.yaml
     in your fork, or they will crashloop.
EOF
}

step_guard
step_preflight
step_packages
step_multipath
step_resolv
step_disks
step_hostpaths
step_k3s
step_seeds
step_longhorn
step_flux
step_report
