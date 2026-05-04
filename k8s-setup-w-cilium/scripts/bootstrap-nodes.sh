#!/usr/bin/env bash
#
# Bootstrap the prerequisites listed in README.md on each host in
# inventory/nodes.ini (assumes the `vm` user already exists on each node):
#   1. Install ansible-core + ansible-lint on the workstation.
#   2. Grant `vm` passwordless sudo via /etc/sudoers.d/90-vm.
#   3. Install inventory/node-ssh-key.pub into ~vm/.ssh/authorized_keys.
#   4. Verify SSH-as-vm + sudo works on every node, then `ansible -m ping`.
#
# Runs from either:
#   - a separate workstation (SSH to all 4 nodes), or
#   - the first node in the inventory (it bootstraps itself via local sudo
#     instead of SSH, and SSHes to the other 3).
# Any target IP that matches a local interface is handled via local sudo;
# everything else goes over SSH.
#
# All remote operations are idempotent — safe to re-run.
#
# Usage:
#   bash scripts/bootstrap-nodes.sh                          # use defaults below
#   BOOTSTRAP_KEY=~/.ssh/id_ed25519 bash scripts/bootstrap-nodes.sh
#
# Env overrides:
#   SSH_USER       user that already exists on each node     (default: vm)
#   BOOTSTRAP_KEY  initial private key for SSH_USER          (default: ssh-agent / default keys, then PRIVKEY_FILE)
#   PUBKEY_FILE    public key to install for SSH_USER        (default: inventory/node-ssh-key.pub)
#   PRIVKEY_FILE   matching private key (used for verify)    (default: inventory/node-ssh-key)
#   INVENTORY      ansible inventory                         (default: inventory/nodes.ini)
#   SUDO_PASS      password for $SSH_USER's sudo             (default: empty -> use `sudo -n`)
#
# Auth note: the initial SSH login as $SSH_USER must already work — either via
# BOOTSTRAP_KEY, an agent-loaded key, or because PRIVKEY_FILE is already
# authorized (e.g. on a re-run). For sudo: if $SSH_USER does not yet have
# passwordless sudo, set SUDO_PASS — the script feeds it via `sudo -S` so the
# initial run can install /etc/sudoers.d/90-vm itself. After the first run,
# SUDO_PASS is no longer needed (the sudoers entry makes `sudo -n` work).
#
# Lab default: in this lab the `vm` user's password is `Password1!`, so:
#   SUDO_PASS='Password1!' bash scripts/bootstrap-nodes.sh

set -euo pipefail

SSH_USER="${SSH_USER:-vm}"
BOOTSTRAP_KEY="${BOOTSTRAP_KEY:-}"
PUBKEY_FILE="${PUBKEY_FILE:-inventory/node-ssh-key.pub}"
PRIVKEY_FILE="${PRIVKEY_FILE:-inventory/node-ssh-key}"
INVENTORY="${INVENTORY:-inventory/nodes.ini}"
SUDO_PASS="${SUDO_PASS:-}"

# -----------------------------------------------------------------------------
# Logging — tee all stdout/stderr to logs/bootstrap-nodes-<timestamp>.log
# -----------------------------------------------------------------------------
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG_DIR="${PROJECT_DIR}/logs"
mkdir -p "$LOG_DIR"
ts="$(date +%Y%m%d-%H%M%S)"
LOG_FILE="${LOG_DIR}/bootstrap-nodes-${ts}.log"
exec > >(tee -a "$LOG_FILE") 2>&1

echo "==================================================================="
echo "bootstrap-nodes.sh start: $(date -Iseconds)"
echo "  host:           $(hostname)"
echo "  user:           $(whoami)"
echo "  cwd:            $(pwd)"
echo "  SSH_USER:       $SSH_USER"
echo "  BOOTSTRAP_KEY:  ${BOOTSTRAP_KEY:-<ssh-agent / default / project key>}"
echo "  PUBKEY_FILE:    $PUBKEY_FILE"
echo "  PRIVKEY_FILE:   $PRIVKEY_FILE"
echo "  INVENTORY:      $INVENTORY"
echo "  SUDO_PASS:      ${SUDO_PASS:+<set, ${#SUDO_PASS} chars>}${SUDO_PASS:-<empty, will use sudo -n>}"
echo "  log:            $LOG_FILE"
echo "==================================================================="

trap 'rc=$?; echo "==================================================================="; echo "bootstrap-nodes.sh end: $(date -Iseconds)  exit=$rc"; echo "==================================================================="' EXIT

# -----------------------------------------------------------------------------
# Sanity checks
# -----------------------------------------------------------------------------
for f in "$INVENTORY" "$PUBKEY_FILE" "$PRIVKEY_FILE"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: required file not found: $f (run from project root)" >&2
    exit 1
  fi
done
chmod 600 "$PRIVKEY_FILE"

# Parse "ansible_host=X.X.X.X" out of the inventory.
mapfile -t NODES < <(grep -oP 'ansible_host=\K[\d.]+' "$INVENTORY")
if [[ ${#NODES[@]} -eq 0 ]]; then
  echo "ERROR: no ansible_host=... entries found in $INVENTORY" >&2
  exit 1
fi
echo ">> Targets (${#NODES[@]}): ${NODES[*]}"

# Local interface IPs — used to detect when a target is "this host" so we can
# skip SSH and just sudo locally. Covers running the script on the first node
# in the inventory.
mapfile -t LOCAL_IPS < <(ip -4 -o addr show | awk '{print $4}' | cut -d/ -f1 | sort -u)
echo ">> Local IPs:        ${LOCAL_IPS[*]:-<none>}"

is_local() {
  local ip="$1" l
  for l in "${LOCAL_IPS[@]}"; do [[ "$l" == "$ip" ]] && return 0; done
  return 1
}

PUBKEY="$(<"$PUBKEY_FILE")"

# Build the SSH key list for the bootstrap leg. Try BOOTSTRAP_KEY first if set,
# then fall back to the project key — that way re-runs work after the project
# key is already authorized.
SSH_BOOT_OPTS=(-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)
[[ -n "$BOOTSTRAP_KEY" ]] && SSH_BOOT_OPTS+=(-i "$BOOTSTRAP_KEY")
SSH_BOOT_OPTS+=(-i "$PRIVKEY_FILE")

SSH_VERIFY_OPTS=(-i "$PRIVKEY_FILE" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10)

# -----------------------------------------------------------------------------
# Remote bootstrap — runs as root via sudo on each node. For nodes whose IP
# matches a local interface, skip SSH and run locally.
# -----------------------------------------------------------------------------
remote_bootstrap() {
  local ip="$1"
  local sudo_flag="-nE"
  [[ -n "$SUDO_PASS" ]] && sudo_flag="-SE"

  if is_local "$ip"; then
    echo ">> [$ip] running locally (matches a local interface)"
  else
    echo ">> [$ip] connecting as ${SSH_USER}@${ip}"
  fi

  # Build stdin = optional password line + remote script body. With sudo -S the
  # first stdin line is consumed as the password; bash -s then reads the rest.
  {
    [[ -n "$SUDO_PASS" ]] && printf '%s\n' "$SUDO_PASS"
    cat <<'REMOTE'
set -euo pipefail

: "${SSH_USER:?}"
: "${PUBKEY:?}"

if ! id -u "$SSH_USER" >/dev/null 2>&1; then
  echo "   [FAIL] user $SSH_USER does not exist on $(hostname)" >&2
  exit 1
fi

# 1. Passwordless sudo.
SUDOERS="/etc/sudoers.d/90-${SSH_USER}"
LINE="${SSH_USER} ALL=(ALL) NOPASSWD:ALL"
if [[ ! -f "$SUDOERS" ]] || ! grep -qxF "$LINE" "$SUDOERS"; then
  echo "   [+] writing $SUDOERS"
  printf '%s\n' "$LINE" > "$SUDOERS"
  chmod 440 "$SUDOERS"
  visudo -cf "$SUDOERS" >/dev/null
else
  echo "   [=] sudoers entry already in place"
fi

# 2. authorized_keys.
HOME_DIR="$(getent passwd "$SSH_USER" | cut -d: -f6)"
SSH_DIR="${HOME_DIR}/.ssh"
AUTH="${SSH_DIR}/authorized_keys"
install -d -m 700 -o "$SSH_USER" -g "$SSH_USER" "$SSH_DIR"
touch "$AUTH"
chmod 600 "$AUTH"
chown "$SSH_USER:$SSH_USER" "$AUTH"
if grep -qxF "$PUBKEY" "$AUTH"; then
  echo "   [=] public key already authorized"
else
  echo "   [+] appending public key to $AUTH"
  printf '%s\n' "$PUBKEY" >> "$AUTH"
fi

echo "   [ok] $(hostname) ready ($(lsb_release -ds 2>/dev/null || grep -E '^PRETTY_NAME=' /etc/os-release | cut -d= -f2- | tr -d '\"'))"
REMOTE
  } | {
    if is_local "$ip"; then
      SSH_USER="$SSH_USER" PUBKEY="$PUBKEY" sudo $sudo_flag bash -s
    else
      ssh "${SSH_BOOT_OPTS[@]}" "${SSH_USER}@${ip}" \
        "SSH_USER=$(printf %q "$SSH_USER") PUBKEY=$(printf %q "$PUBKEY") sudo $sudo_flag bash -s"
    fi
  }
}

# -----------------------------------------------------------------------------
# Verify — confirm $SSH_USER can sudo to root on each node. For local IPs,
# skip SSH and call sudo directly.
# -----------------------------------------------------------------------------
verify_node() {
  local ip="$1"
  local out how
  if is_local "$ip"; then
    how="local sudo"
    out="$(sudo -n whoami 2>&1)" || { echo "   [FAIL] $ip — local sudo -n failed: $out"; return 1; }
  else
    how="ssh ${SSH_USER}@${ip}"
    out="$(ssh "${SSH_VERIFY_OPTS[@]}" "${SSH_USER}@${ip}" 'sudo -n whoami' 2>&1)" || {
      echo "   [FAIL] $ip — verify failed: $out"
      return 1
    }
  fi
  if [[ "$out" != "root" ]]; then
    echo "   [FAIL] $ip — expected sudo whoami=root via $how, got: $out"
    return 1
  fi
  echo "   [ok]   $ip — sudo -n whoami = root (via $how)"
}

# -----------------------------------------------------------------------------
# Drive
# -----------------------------------------------------------------------------
echo
echo "=== Phase 1/4: install workstation tooling (ansible-core, ansible-lint) ==="
need_install=()
command -v ansible      >/dev/null 2>&1 || need_install+=(ansible-core)
command -v ansible-lint >/dev/null 2>&1 || need_install+=(ansible-lint)
if (( ${#need_install[@]} > 0 )); then
  echo "   [+] installing: ${need_install[*]}"
  sudo apt-get update
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y "${need_install[@]}"
else
  echo "   [=] ansible-core and ansible-lint already installed"
fi
ansible      --version | head -n1
ansible-lint --version | head -n1

echo
echo "=== Phase 2/4: bootstrap nodes ==="
fail=0
for ip in "${NODES[@]}"; do
  if ! remote_bootstrap "$ip"; then
    echo "   [FAIL] $ip — bootstrap failed"
    fail=$((fail + 1))
  fi
done
if (( fail > 0 )); then
  echo "ERROR: bootstrap failed on $fail node(s)" >&2
  exit 1
fi

echo
echo "=== Phase 3/4: verify SSH + sudo as $SSH_USER ==="
for ip in "${NODES[@]}"; do
  verify_node "$ip" || fail=$((fail + 1))
done
if (( fail > 0 )); then
  echo "ERROR: verify failed on $fail node(s)" >&2
  exit 1
fi

echo
echo "=== Phase 4/4: ansible -m ping ==="
ansible -i "$INVENTORY" k8s_cluster -m ping

echo
echo ">> All prerequisites satisfied. Next:"
echo "     bash run.sh playbooks/apt-update-upgrade.yaml"
echo "     bash run.sh playbooks/install-cluster.yaml"
