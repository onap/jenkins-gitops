#!/bin/sh
# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 ONAP Contributors
# Stand up a throwaway k3d cluster that imitates the real layout:
#   ArgoCD + External Secrets Operator (installed here, as the private
#   infrastructure repo will do on Vexxhost), then Jenkins deployed by ArgoCD
#   from this repository.
#
# github.com/onap/jenkins-gitops does not exist yet, so the working tree is
# published to a small git server inside the cluster and ArgoCD syncs from
# there. Re-run `local/cluster-up.sh sync` after editing files.
#
# Usage: local/cluster-up.sh            create everything and sync
#        local/cluster-up.sh sync       publish the working tree again
#        local/cluster-up.sh down       delete the cluster
set -eu
repo="$(cd "$(dirname "$0")/.." && pwd)"
cluster=onap-jenkins
image=onap-jenkins:local
ns=jenkins-local
argocd_version=v3.1.8
eso_version=0.20.4

publish_working_tree() {
  echo "--- publishing the working tree to the in-cluster git server"
  tmp="$(mktemp -d)"
  # Tracked and untracked (not ignored) files, so uncommitted edits are tested.
  git -C "$repo" ls-files -z --cached --others --exclude-standard \
    | tar --null -C "$repo" -T - -cf - | tar -C "$tmp/" -xf -
  git -C "$tmp" init -q -b main
  git -C "$tmp" -c user.name=local -c user.email=local@localhost add -A
  git -C "$tmp" -c user.name=local -c user.email=local@localhost commit -q -m "working tree"
  kubectl -n git port-forward svc/git-server 9418:9418 >/dev/null 2>&1 &
  pf=$!
  sleep 2
  git -C "$tmp" push -q -f git://localhost:9418/jenkins-gitops.git main
  kill "$pf"
  rm -rf "$tmp"
  kubectl -n argocd annotate app jenkins-local argocd.argoproj.io/refresh=hard --overwrite >/dev/null 2>&1 || true
}

case "${1:-up}" in
  down)
    k3d cluster delete "$cluster"
    exit 0
    ;;
  sync)
    publish_working_tree
    exit 0
    ;;
  up) ;;
  *)
    echo "usage: $0 [up|sync|down]" >&2; exit 2 ;;
esac

k3d cluster create "$cluster" --servers 1 --agents 0 \
  --k3s-arg '--disable=traefik@server:0' \
  -p '8080:30080@server:0' -p '8081:30081@server:0' --wait
echo "--- importing $image"
k3d image import "$image" -c "$cluster"

echo "--- installing ArgoCD $argocd_version"
kubectl create namespace argocd
kubectl apply -n argocd -f "https://raw.githubusercontent.com/argoproj/argo-cd/$argocd_version/manifests/install.yaml" >/dev/null
kubectl -n argocd patch cm argocd-cmd-params-cm --type merge -p '{"data":{"server.insecure":"true"}}'
kubectl -n argocd patch svc argocd-server --type merge \
  -p '{"spec":{"type":"NodePort","ports":[{"name":"http","port":80,"targetPort":8080,"nodePort":30081},{"name":"https","port":443,"targetPort":8080}]}}'
kubectl -n argocd rollout restart deploy/argocd-server
kubectl -n argocd rollout status deploy/argocd-server --timeout=300s
kubectl -n argocd rollout status deploy/argocd-repo-server --timeout=300s

echo "--- installing External Secrets Operator $eso_version"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  --version "$eso_version" -n external-secrets --create-namespace --wait

echo "--- in-cluster git server"
kubectl apply -f "$repo/local/git-server.yaml"
kubectl -n git rollout status deploy/git-server --timeout=120s

echo "--- namespace and fake secret store"
kubectl create namespace "$ns"
"$repo/local/make-fake-secret-store.sh" "$ns"

publish_working_tree

echo "--- ArgoCD application"
kubectl apply -f "$repo/local/argocd-app.yaml"

echo
echo "ArgoCD:  http://localhost:8081  (user admin)"
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
echo "Jenkins: http://localhost:8080  (user admin, password admin) once the pod is ready"
echo "Watch:   kubectl -n $ns get pods -w"
