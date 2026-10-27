#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 ONAP Contributors

# Boot the controller image with base/jenkins/jcasc/*.yaml and dummy secrets,
# and fail unless Jenkins reports "fully up and running" with no JCasC error.
#
# This is the real check that every JCasC file is accepted by the plugin
# versions baked into the image. Run it locally before pushing JCasC or
# plugin changes; CI runs it in validate-jcasc.yaml.
#
# Usage: scripts/casc-smoke-test.sh [image]      default image: onap-jenkins:local
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
image="${1:-onap-jenkins:local}"
name="onap-jenkins-casc-smoke"
secrets="$(mktemp -d)"
casc="$(mktemp -d)"
# shellcheck disable=SC2329  # invoked through the trap below
cleanup() {
  docker logs "$name" > "$repo/casc-smoke-test.log" 2>&1 || true
  docker rm -f "$name" >/dev/null 2>&1 || true
  rm -rf "$secrets" "$casc"
}
trap cleanup EXIT

grep -v '^#' "$repo/base/jenkins/secret-keys.txt" | while read -r key; do
  [ -n "$key" ] || continue
  case "$key" in
    *-secret-bytes) printf 'ZHVtbXk=' > "$secrets/$key" ;;
    *) printf 'dummy' > "$secrets/$key" ;;
  esac
done
printf 'admin' > "$secrets/local-admin-password"

# Same file set the chart ships for the local environment: everything except
# 15-auth.yaml (SAML), plus the local admin realm.
for f in "$repo"/base/jenkins/jcasc/*.yaml; do
  case "$(basename "$f")" in 15-auth.yaml) ;; *) cp "$f" "$casc/" ;; esac
done
sed -n '/zz-local-auth: |/,/^    [a-z]/p' "$repo/local/values.yaml" \
  | sed '1d;$d' | sed 's/^          //' > "$casc/zz-local-auth.yaml"
chmod -R a+rX "$casc" "$secrets"

docker rm -f "$name" >/dev/null 2>&1 || true
docker run -d --name "$name" \
  -v "$casc:/var/jenkins_home/casc_configs:ro" \
  -v "$secrets:/run/secrets/jcasc:ro" \
  -e CASC_JENKINS_CONFIG=/var/jenkins_home/casc_configs \
  -e SECRETS=/run/secrets/jcasc \
  -e GERRIT_AUTH_KEY_FILE=/run/secrets/jcasc/gerrit-trigger-ssh-key \
  -e JENKINS_URL=http://localhost:8080/ \
  -e 'JENKINS_ADMIN_ADDRESS=Jenkins <donotreply@localhost>' \
  -e SILO=local -e JENKINS_HOSTNAME=local -e SIGUL_KEY=local -e MASTER_RTD_PROJECT=doc-test \
  "$image" >/dev/null

echo "waiting for Jenkins ($image)..."
i=0
while [ "$i" -lt 120 ]; do
  logs="$(docker logs "$name" 2>&1 || true)"
  if printf '%s' "$logs" | grep -q 'Jenkins is fully up and running'; then
    echo "OK: Jenkins is fully up and running"
    printf '%s' "$logs" | grep -E 'ConfiguratorException|Failed ConfigurationAsCode' && exit 1
    exit 0
  fi
  if printf '%s' "$logs" | grep -qE 'Failed to initialize Jenkins|Jenkins stopped'; then
    echo "FAIL: Jenkins did not start"
    printf '%s' "$logs" | grep -E 'Exception|Caused|SEVERE' | grep -v GerritConnection | head -30
    exit 1
  fi
  i=$((i + 1)); sleep 5
done
echo "FAIL: timed out"; exit 1
