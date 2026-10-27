<!--
SPDX-License-Identifier: Apache-2.0
SPDX-FileCopyrightText: 2026 ONAP Contributors
-->

# ONAP Jenkins GitOps

Declarative deployment of the ONAP Jenkins controllers
(<https://jenkins.onap.org>, <https://jenkins.onap.org/sandbox>) on
Kubernetes with ArgoCD, Helm and Jenkins Configuration as Code (JCasC).

Git holds the desired state. A separate infrastructure repository
provisions the cluster, ArgoCD and the External Secrets Operator; this
repository holds everything that describes Jenkins itself.

## Layout

<!-- markdownlint-disable MD013 -->

| Path | Purpose |
| --- | --- |
| `build/` | Controller image: `jenkins/jenkins:2.462.3-lts-jdk11` plus the 162 plugins production runs, at the same versions |
| `base/jenkins/` | Helm wrapper chart around the official Jenkins chart |
| `base/jenkins/jcasc/` | JCasC files generated from the production export; secret values are `${key}` references |
| `base/jenkins/secret-keys.txt` | Every secret key the configuration needs (879) |
| `sandbox/`, `production/` | Per-environment Helm values |
| `local/` | Throwaway k3d cluster for testing |
| `argocd-apps/`, `root-app.yaml` | ArgoCD app-of-apps definitions |
| `scripts/casc-smoke-test.sh` | Boots the image with the JCasC files and dummy secrets |

<!-- markdownlint-enable MD013 -->

## How configuration reaches Jenkins

1. `templates/jcasc-configmaps.yaml` turns each file in
   `base/jenkins/jcasc/` into a ConfigMap.
2. The Jenkins chart's config-reload sidecar writes them into the pod and
   asks Jenkins to reload JCasC. A config change needs no restart.
3. Secrets stay out of Git. `templates/external-secret.yaml` asks the
   External Secrets Operator for one Kubernetes Secret,
   `jenkins-jcasc-secrets`, with one entry per line of `secret-keys.txt`.
   The pod mounts it at `/run/secrets/jcasc`, and JCasC resolves `${key}`
   from the file of that name.
4. `<env>/values.yaml` sets environment-specific values (`SILO`,
   `JENKINS_URL`, heap size, ...) as container environment variables.

### Secret key naming

| Credential type | Keys |
| --- | --- |
| Username/password `id` | `<id>-username`, `<id>-password` |
| Secret text `id` | `<id>-secret` |
| SSH private key `id` | `<id>-username`, `<id>-private-key` |
| Secret file `id` | `<id>-secret-bytes` (base64) |
| OpenStack `id` | `<id>-username`, `<id>-password` |
| Gerrit Trigger SSH key | `gerrit-trigger-ssh-key` (a file path) |
| WhiteSource | `whitesource-api-token`, `whitesource-user-key` |

## Local testing

Requirements: `docker`, `k3d`, `kubectl`, `helm`.

```sh
docker build -t onap-jenkins:local build   # image with all plugins
scripts/casc-smoke-test.sh                 # ~3 min: does JCasC load?
local/cluster-up.sh                        # k3d + ArgoCD + ESO + Jenkins
```

`cluster-up.sh` installs ArgoCD and External Secrets the way the
infrastructure repository will, publishes the working tree to a small git
server inside the cluster, and lets ArgoCD deploy `local/values.yaml`.
Jenkins answers at <http://localhost:8080> (admin / admin), ArgoCD at
<http://localhost:8081>. Run `local/cluster-up.sh sync` after editing
files and `local/cluster-up.sh down` to delete the cluster.

The local environment swaps SAML for a local admin: it excludes
`15-auth.yaml` and adds `zz-local-auth`. An ESO `fake` store serves dummy
secrets. Everything else matches sandbox and production.

## Making a change

<!-- markdownlint-disable MD013 -->

| Change | Where |
| --- | --- |
| Jenkins version or plugins | `build/Dockerfile`, `build/plugins.txt`; CI publishes `ghcr.io/onap/jenkins:<version>-<sha>`; pin it in `<env>/values.yaml` |
| Node templates (OpenStack) | `base/jenkins/jcasc/40-clouds.yaml` |
| Credentials | `base/jenkins/jcasc/50-credentials.yaml` and `secret-keys.txt`; the value goes into the secret store |
| Managed files, Maven settings | `base/jenkins/jcasc/60-*.yaml`, `61-*.yaml` |
| Permissions, SAML | `base/jenkins/jcasc/15-auth.yaml` |
| Sizing, URLs, ingress | `<env>/values.yaml` |

<!-- markdownlint-enable MD013 -->

Before pushing, run `prek run --files <changed files>`,
`helm template jenkins base/jenkins -f <env>/values.yaml`, and
`scripts/casc-smoke-test.sh` for anything under `build/` or `jcasc/`.

## Known gaps

- Storage class, ingress class, TLS issuer, hostnames and the secret store
  name depend on the Vexxhost cluster, which does not exist yet. The values
  files mark each one.
- The sandbox JCasC export needs a sandbox API token. Until then the
  sandbox values come from
  `ci-management/jenkins-config/global-vars-sandbox.sh`.
- Both this repository (`05-views.yaml`) and JJB
  (`ci-management/jjb/ci-management/ci-management-views.yaml`) define the
  views. Pick one owner before cut-over.
- `build/ref/*.xml` seeds the Nexus Platform plugin's instance ID on first
  start; without it the plugin aborts boot on an empty `JENKINS_HOME`.
