# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2026 ONAP Contributors

# Jenkins controller image for jenkins.onap.org
#
# Replicates the current production controller: Jenkins 2.462.3 on Java 11
# with the exact plugin set and versions installed today. Jobs run on
# OpenStack agents, not on the controller, so no build tooling is added here.
#
# Upgrade path: bump the base image tag and the pins in plugins.txt in one
# pull request; ArgoCD rolls the new image out.
FROM jenkins/jenkins:2.462.3-lts-jdk11

# Configuration is supplied by JCasC; never run the setup wizard.
ENV JAVA_OPTS="-Djenkins.install.runSetupWizard=false"

COPY plugins.txt plugins-disabled.txt /usr/share/jenkins/ref/

# Files seeded into an empty JENKINS_HOME on first start. See ref/*.xml for
# why each one exists.
COPY ref/ /usr/share/jenkins/ref/

# Install every plugin at its pinned version. --latest=false stops the CLI
# from resolving dependencies to newer releases than the ones pinned.
RUN jenkins-plugin-cli --verbose --latest false \
      --plugin-file /usr/share/jenkins/ref/plugins.txt

# Recreate the "installed but disabled" state of production. Jenkins copies
# everything under /usr/share/jenkins/ref into JENKINS_HOME on first start,
# and honours a <name>.jpi.disabled marker next to the plugin archive.
RUN grep -v '^#' /usr/share/jenkins/ref/plugins-disabled.txt \
      | grep -v '^$' \
      | while read -r plugin; do \
          test -f "/usr/share/jenkins/ref/plugins/${plugin}.jpi" || exit 1; \
          touch "/usr/share/jenkins/ref/plugins/${plugin}.jpi.disabled"; \
        done
