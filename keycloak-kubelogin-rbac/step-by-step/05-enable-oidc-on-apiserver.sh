#!/usr/bin/env bash
# 05-enable-oidc-on-apiserver.sh — turn on OIDC authentication on the K8s
# API server by editing the static pod manifest at
#   /etc/kubernetes/manifests/kube-apiserver.yaml
# on the control-plane node, then wait for kubelet to restart it.
#
# Two changes are made:
#
#   1. Add --oidc-* flags to spec.containers[0].command:
#        --oidc-issuer-url=http://keycloak.k8s.lab/realms/k8s
#        --oidc-client-id=kubernetes
#        --oidc-username-claim=preferred_username
#        --oidc-username-prefix=oidc:
#        --oidc-groups-claim=groups
#        --oidc-groups-prefix=oidc:
#        --oidc-signing-algs=RS256
#
#   2. Add a hostAlias under spec so the API server (which uses its own
#      kubelet-managed /etc/hosts, not the host's) can resolve
#      keycloak.k8s.lab → MetalLB ingress IP for OIDC discovery.
#
# A timestamped backup of kube-apiserver.yaml is left next to the original
# before any change is made. Re-running the script is safe — flags and
# hostAliases are added only if absent.
#
# Why the "oidc:" prefix on usernames and groups: it's a security control,
# not just naming. Without it, anyone who can mint a Keycloak group named
# "system:masters" gets implicit cluster-admin via the built-in binding.
# The prefix puts every OIDC identity in a namespace that can't collide
# with built-in or cert-based ones.

set -euo pipefail

CONTROL_PLANE_HOST="${CONTROL_PLANE_HOST:-192.168.48.31}"
CONTROL_PLANE_USER="${CONTROL_PLANE_USER:-vm}"
SSH_KEY="${SSH_KEY:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/../k8s-setup-w-cilium/inventory/node-ssh-key}"
INGRESS_LB_IP="${INGRESS_LB_IP:-192.168.48.202}"
KEYCLOAK_HOST="${KEYCLOAK_HOST:-keycloak.k8s.lab}"
ISSUER="${ISSUER:-http://${KEYCLOAK_HOST}/realms/k8s}"

if [ ! -f "$SSH_KEY" ]; then
  echo "ERROR: SSH key not found at $SSH_KEY (override with SSH_KEY=...)" >&2
  exit 1
fi

ssh_cp() {
  ssh -i "$SSH_KEY" -o StrictHostKeyChecking=accept-new \
    "${CONTROL_PLANE_USER}@${CONTROL_PLANE_HOST}" "$@"
}

echo "Editing /etc/kubernetes/manifests/kube-apiserver.yaml on ${CONTROL_PLANE_HOST}..."

# Pipe a python3 script over SSH and run it as root. Python 3 is in Ubuntu's
# base image, no extra packages needed (we use stdlib text manipulation
# rather than PyYAML so this works on a stock control-plane node).
#
# The heredoc is UNQUOTED so the local shell substitutes ${INGRESS_LB_IP},
# ${KEYCLOAK_HOST}, ${ISSUER} into the Python source before it crosses ssh.
# That avoids relying on sudoers env_keep to pass env vars through sudo.
ssh_cp "sudo python3 -" <<PYEOF
import os, sys, shutil
from datetime import datetime

PATH = '/etc/kubernetes/manifests/kube-apiserver.yaml'
INGRESS_IP    = "${INGRESS_LB_IP}"
KEYCLOAK_HOST = "${KEYCLOAK_HOST}"
ISSUER        = "${ISSUER}"

OIDC_FLAGS = [
    f'--oidc-issuer-url={ISSUER}',
    '--oidc-client-id=kubernetes',
    '--oidc-username-claim=preferred_username',
    '--oidc-username-prefix=oidc:',
    '--oidc-groups-claim=groups',
    '--oidc-groups-prefix=oidc:',
    '--oidc-signing-algs=RS256',
]

with open(PATH) as f:
    lines = f.read().splitlines()

backup = f'{PATH}.bak-{datetime.now().strftime("%Y%m%dT%H%M%S")}'
shutil.copy(PATH, backup)
print(f'Backed up to {backup}', file=sys.stderr)

# 1. Find existing --oidc-* flags so we don't duplicate. Match both
# unquoted ("- --oidc-...") and single-quoted ("- '--oidc-...'") forms.
existing_keys = set()
for line in lines:
    s = line.lstrip()
    if s.startswith("- '--oidc-"):
        existing_keys.add(s[3:].split('=', 1)[0])
    elif s.startswith('- --oidc-'):
        existing_keys.add(s[2:].split('=', 1)[0])

# Find end of the command block. kubeadm's layout is:
#   spec:
#     containers:
#     - command:
#       - kube-apiserver
#       - --foo=bar
#       ...
#       image: ...
# So the "- command:" line itself is at indent 2 (the dash at col 2,
# "command:" key at col 4). Each item under the command list is at
# indent 4 (dash at col 4). The block ends at the first sibling line
# (e.g. "    image:") that does not start with "    - ".
in_cmd = False
cmd_end = None
for i, line in enumerate(lines):
    if line.rstrip() == '  - command:':
        in_cmd = True
        continue
    if in_cmd:
        if line.startswith('    - '):
            continue
        cmd_end = i
        break

if cmd_end is None:
    sys.exit('ERROR: could not locate end of command block in kube-apiserver.yaml')

new_flag_lines = []
for flag in OIDC_FLAGS:
    key = flag.split('=', 1)[0]
    if key in existing_keys:
        continue
    # Single-quote each flag because some values end in ":" (oidc-username-prefix,
    # oidc-groups-prefix). YAML treats a trailing colon as a mapping key, which
    # would parse the flag as a dict instead of a string and break the kubelet.
    new_flag_lines.append(f"    - '{flag}'")

if new_flag_lines:
    lines = lines[:cmd_end] + new_flag_lines + lines[cmd_end:]
    print(f'Added {len(new_flag_lines)} OIDC flag(s).', file=sys.stderr)
else:
    print('All OIDC flags already present.', file=sys.stderr)

# 2. hostAliases — insert under spec, before "  containers:".
has_host_aliases = any(l.rstrip() == '  hostAliases:' for l in lines)
needed_hostname_line = f'    - {KEYCLOAK_HOST}'

if not has_host_aliases:
    inserted = False
    for i, line in enumerate(lines):
        if line.rstrip() == '  containers:':
            block = [
                '  hostAliases:',
                f'  - ip: {INGRESS_IP}',
                '    hostnames:',
                needed_hostname_line,
            ]
            lines = lines[:i] + block + lines[i:]
            inserted = True
            break
    if not inserted:
        sys.exit('ERROR: could not find "  containers:" anchor in kube-apiserver.yaml')
    print(f'Added hostAliases: {INGRESS_IP} → {KEYCLOAK_HOST}', file=sys.stderr)
else:
    if any(l.rstrip() == needed_hostname_line for l in lines):
        print('hostAliases already includes the lab entry.', file=sys.stderr)
    else:
        print(f'WARNING: hostAliases is set but does not include "{KEYCLOAK_HOST}".', file=sys.stderr)
        print('         Edit kube-apiserver.yaml manually before continuing.', file=sys.stderr)

# Atomic write so kubelet can never read a half-written manifest.
tmp = PATH + '.tmp'
with open(tmp, 'w') as f:
    f.write('\n'.join(lines) + '\n')
os.replace(tmp, PATH)
print('kube-apiserver.yaml updated.', file=sys.stderr)
PYEOF

echo
echo "Waiting for kubelet to recreate the kube-apiserver pod..."
# kubelet reacts to manifest changes within a few seconds. The API will be
# unreachable briefly while the pod restarts.
sleep 5

deadline=$(( $(date +%s) + 180 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if kubectl get --raw=/readyz >/dev/null 2>&1; then
    echo "API server is reachable again."
    break
  fi
  printf '.'
  sleep 3
done
echo

# Confirm the OIDC flags actually took effect.
echo "Confirming OIDC flags are live on the running kube-apiserver pod:"
kubectl get pod -n kube-system \
  -l component=kube-apiserver -o jsonpath='{.items[0].spec.containers[0].command}' \
  | tr ',' '\n' | grep --color=never -- '--oidc-' || {
  echo "ERROR: OIDC flags not visible on the live kube-apiserver. Investigate." >&2
  exit 1
}

echo
echo "OIDC is enabled on the API server. Next: 06-configure-kubeconfig.sh"
