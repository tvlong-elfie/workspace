FROM mcr.microsoft.com/vscode/devcontainers/python:1-3.12-bookworm

USER root

ARG DEBIAN_FRONTEND=noninteractive

# Trust the Netskope TLS-inspection CA exported by export-host-certs.sh (absent off-VPN/non-macOS).
COPY k8s/dev/certs/ /usr/local/share/ca-certificates/netskope/
RUN update-ca-certificates
# Point tools that ship their own CA bundle (node, pip/requests, uv, gcloud) at the system bundle.
ENV SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt \
    CURL_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    REQUESTS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt \
    NODE_EXTRA_CA_CERTS=/etc/ssl/certs/ca-certificates.crt \
    CLOUDSDK_CORE_CUSTOM_CA_CERTS_FILE=/etc/ssl/certs/ca-certificates.crt

RUN rm -f /etc/apt/sources.list.d/yarn.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
        apt-transport-https \
        ca-certificates \
        curl \
        gnupg \
        zsh \
        git \
    && mkdir -p /etc/apt/keyrings \
    && curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg \
        | gpg --dearmor -o /etc/apt/keyrings/cloud.google.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" \
        > /etc/apt/sources.list.d/google-cloud-sdk.list \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends google-cloud-cli gh openssh-server \
    # The package generates shared default host keys at install time. Remove them in this layer
    # so they never ship in the image; entrypoint.sh creates per-volume host keys instead.
    && rm -f /etc/ssh/ssh_host_* \
    # zsh is the login shell for the dev user, matching the devcontainer setup.
    && chsh -s /usr/bin/zsh vscode \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

COPY --from=ghcr.io/astral-sh/uv:latest /uv /uvx /usr/local/bin/

# Node.js (Claude Code runs on it) from the NodeSource apt repo, same pattern as gcloud and gh above.
RUN curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends nodejs \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# kubectl from the official Kubernetes apt repo, pinned to the cluster's minor version (v1.31).
RUN curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key \
        | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends kubectl \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# kubectx and kubens from a pinned release. Each tarball is checked against its SHA-256 digest.
RUN set -eux; \
    arch="$(dpkg --print-architecture)"; \
    case "$arch" in \
      amd64) asset=x86_64; ctx_sha=08e031c54fbffb3f100e904e4eae94bba2730fedf4869921fda79e4d7a8f5d4c; ns_sha=326c021c7b35468ed9a187b361198d0f22ae32828139c65eb6670c0d8301cc09 ;; \
      arm64) asset=arm64; ctx_sha=1dac2072216689e773325cb7587b858ea7415706ebcf04e23bf80e7e70555340; ns_sha=37058abe82ef20c93b44f3dc8ca2382dbb95d416cec958fbf7b8f79f011be86c ;; \
      *) echo "unsupported architecture: $arch" >&2; exit 1 ;; \
    esac; \
    base=https://github.com/ahmetb/kubectx/releases/download/v0.11.0; \
    cd /tmp; \
    curl -fsSLO "$base/kubectx_v0.11.0_linux_${asset}.tar.gz"; \
    curl -fsSLO "$base/kubens_v0.11.0_linux_${asset}.tar.gz"; \
    echo "$ctx_sha  kubectx_v0.11.0_linux_${asset}.tar.gz" | sha256sum -c -; \
    echo "$ns_sha  kubens_v0.11.0_linux_${asset}.tar.gz" | sha256sum -c -; \
    tar -xzf "kubectx_v0.11.0_linux_${asset}.tar.gz" -C /usr/local/bin kubectx; \
    tar -xzf "kubens_v0.11.0_linux_${asset}.tar.gz" -C /usr/local/bin kubens; \
    rm -f /tmp/kubectx_*.tar.gz /tmp/kubens_*.tar.gz; \
    chmod 755 /usr/local/bin/kubectx /usr/local/bin/kubens

COPY k8s/dev/entrypoint.sh /usr/local/bin/elfie-dev-entrypoint
RUN chmod 755 /usr/local/bin/elfie-dev-entrypoint

USER vscode

# Claude Code goes in the vscode user's own npm prefix. A root-owned global prefix makes
# `claude update` fail with "npm global folder isn't writable".
# The prefix goes in ~/.npmrc, not an env var, because SSH sessions don't inherit ENV and
# `claude update` runs npm from there.
ENV PATH=/home/vscode/.npm-global/bin:$PATH
# oh-my-zsh for the dev user. The base image usually ships it already; the check keeps this idempotent.
RUN [ -d /home/vscode/.oh-my-zsh ] || git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git /home/vscode/.oh-my-zsh

# Login shells (bash via ~/.profile, zsh via ~/.zshenv) reset PATH, so add the bin dir there too.
RUN npm config set prefix /home/vscode/.npm-global \
    && npm install -g @anthropic-ai/claude-code \
    && echo 'export PATH="$HOME/.npm-global/bin:$PATH"' | tee -a /home/vscode/.profile /home/vscode/.zshenv > /dev/null

EXPOSE 2222
ENTRYPOINT ["/usr/local/bin/elfie-dev-entrypoint"]
