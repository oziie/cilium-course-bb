# syntax=docker/dockerfile:1
#
# Bulut Bilisimciler lab image for the Cilium & eBPF course.
#
# Same toolset as setup-ubuntu/setup-ubuntu.sh, baked in at build time so every
# scenario starts with the CLIs ready: Docker Engine, kubectl, kind, helm,
# cilium-cli, hubble-cli. No cluster is created: step 1 of each scenario does that.
#
# Build (multi-arch):
#   docker buildx build --platform linux/amd64,linux/arm64 -t <registry>/cilium-course-lab:1.18 bb-image/
#
# kind runs its nodes as Docker containers, so when this image is run as a
# container (not booted as a VM) it needs Docker-in-Docker:
#   docker run -it --privileged -v /var/lib/docker <registry>/cilium-course-lab:1.18
#
FROM ubuntu:24.04

ARG TARGETARCH=amd64

# Bump these together. hubble-cli must match the Cilium minor the labs install
# (1.18): a newer CLI fails against Cilium 1.18 with "invalid fieldmask".
ARG KUBECTL_VERSION=v1.37.1
ARG KIND_VERSION=v0.33.0
ARG HELM_VERSION=v3.22.0
ARG CILIUM_CLI_VERSION=v0.20.1
ARG HUBBLE_VERSION=v1.18.6

ENV DEBIAN_FRONTEND=noninteractive

# Base tools + Docker Engine from the official Docker apt repository.
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg jq git less iproute2 iptables procps bash-completion \
 && install -m 0755 -d /etc/apt/keyrings \
 && curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc \
 && chmod a+r /etc/apt/keyrings/docker.asc \
 && . /etc/os-release \
 && echo "deb [arch=${TARGETARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable" \
      > /etc/apt/sources.list.d/docker.list \
 && apt-get update \
 && apt-get install -y --no-install-recommends \
      docker-ce docker-ce-cli containerd.io docker-buildx-plugin \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /tmp/dl

# kubectl
RUN curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl" \
 && echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${TARGETARCH}/kubectl.sha256")  kubectl" \
      | sha256sum --check --status \
 && install -m 0755 kubectl /usr/local/bin/kubectl \
 && rm -f kubectl

# kind
RUN curl -fsSL --remote-name-all \
      "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${TARGETARCH}{,.sha256sum}" \
 && sha256sum --check --status "kind-linux-${TARGETARCH}.sha256sum" \
 && install -m 0755 "kind-linux-${TARGETARCH}" /usr/local/bin/kind \
 && rm -f kind-linux-*

# helm
RUN curl -fsSL --remote-name-all \
      "https://get.helm.sh/helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz{,.sha256sum}" \
 && sha256sum --check --status "helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz.sha256sum" \
 && tar -xzf "helm-${HELM_VERSION}-linux-${TARGETARCH}.tar.gz" --strip-components=1 "linux-${TARGETARCH}/helm" \
 && install -m 0755 helm /usr/local/bin/helm \
 && rm -f helm helm-*

# cilium-cli and hubble-cli ship identical release layouts. RUN steps use plain
# /bin/sh: the OCI image format (Podman/Buildah default) ignores SHELL.
RUN for spec in "cilium/cilium-cli cilium ${CILIUM_CLI_VERSION}" "cilium/hubble hubble ${HUBBLE_VERSION}"; do \
      set -- $spec; repo=$1; bin=$2; ver=$3; \
      tarball="${bin}-linux-${TARGETARCH}.tar.gz"; \
      curl -fsSL --remote-name-all "https://github.com/${repo}/releases/download/${ver}/${tarball}{,.sha256sum}" \
      && sha256sum --check --status "${tarball}.sha256sum" \
      && tar -C /usr/local/bin -xzf "$tarball" \
      && rm -f "$tarball" "${tarball}.sha256sum" \
      || exit 1; \
    done

# Shell completion, so learners can tab through kubectl/cilium/hubble commands.
RUN for bin in kubectl kind helm cilium hubble; do \
      "$bin" completion bash > "/etc/bash_completion.d/${bin}"; \
    done \
 && echo 'source /etc/bash_completion' >> /root/.bashrc

WORKDIR /root

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 0755 /usr/local/bin/entrypoint.sh

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash", "-l"]
