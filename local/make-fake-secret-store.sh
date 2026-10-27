#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 ONAP Contributors
# Create a "fake" External Secrets SecretStore holding dummy values for every
# key in base/jenkins/secret-keys.txt, plus the local admin password.
#
# The ExternalSecret rendered by the chart then produces jenkins-jcasc-secrets
# exactly as it would from a real store.
#
# Usage: local/make-fake-secret-store.sh <namespace>
set -eu
ns="${1:?namespace required}"
repo="$(cd "$(dirname "$0")/.." && pwd)"
out="$(mktemp)"
trap 'rm -f "$out"' EXIT

{
  cat <<EOF
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: fake-local
  namespace: $ns
spec:
  provider:
    fake:
      data:
        - key: local-admin-password
          value: admin
EOF
  grep -v '^#' "$repo/base/jenkins/secret-keys.txt" | while read -r key; do
    [ -n "$key" ] || continue
    case "$key" in
      *-secret-bytes) value='ZHVtbXk=' ;;   # base64("dummy")
      *) value='dummy' ;;
    esac
    printf '        - key: %s\n          value: %s\n' "$key" "$value"
  done
} > "$out"

kubectl apply -f "$out"
echo "SecretStore fake-local: $(grep -c '        - key:' "$out") keys (admin password: admin)"
