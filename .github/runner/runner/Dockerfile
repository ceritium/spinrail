# One job, then gone: the manager starts a fresh container for every job.
#
# Ruby and master's spinel and spinelkit (per toolchain.mk) are baked
# into /opt/vendor, so a job only fetches the tep fork and compiles. The
# runner managers build it, supplying deps/ from master per image.conf.
FROM ghcr.io/actions/actions-runner:latest

USER root
RUN apt-get update && apt-get install --no-install-recommends -y \
      build-essential git pkg-config curl ca-certificates \
      libsqlite3-dev sqlite3 libssl-dev libyaml-dev libffi-dev zlib1g-dev libgmp-dev \
      iptables util-linux openssh-client \
    && rm -rf /var/lib/apt/lists/*

# The base image gives runner passwordless sudo; jobs here get none, so they
# cannot lift the network rules the entrypoint sets.
RUN gpasswd -d runner sudo >/dev/null 2>&1 || true; \
    rm -f /etc/sudoers.d/runner; \
    sed -i '/^runner /d' /etc/sudoers

ARG TARGETARCH
ARG RUBY_VERSION

# Ruby: the prebuilt one ruby/setup-ruby installs on GitHub's Ubuntu 24.04
# runners.
RUN set -eu; \
    case "$TARGETARCH" in amd64) ruby_arch=x64 ;; arm64) ruby_arch=arm64 ;; *) exit 1 ;; esac; \
    prefix=/opt/hostedtoolcache/Ruby/${RUBY_VERSION}/${ruby_arch}; \
    mkdir -p "$prefix"; \
    curl -fsSL "https://github.com/ruby/ruby-builder/releases/download/ruby-${RUBY_VERSION}/ruby-${RUBY_VERSION}-ubuntu-24.04-${ruby_arch}.tar.gz" \
      | tar -xz -C "$prefix" --strip-components=1; \
    ln -s "$prefix" /opt/ruby; \
    /opt/ruby/bin/ruby -v

# SPINRAIL_VENDOR: where the spinrail CLI and the toolchain find spinel and tep.
ENV PATH=/opt/ruby/bin:$PATH \
    SPINRAIL_VENDOR=/opt/vendor \
    LANG=C.UTF-8

COPY entrypoint.sh /entrypoint.sh
COPY fence-network /usr/local/sbin/fence-network
RUN chmod 755 /entrypoint.sh /usr/local/sbin/fence-network

# spinel and spinelkit only: the job fetches tep at toolchain.mk's TEP_REF.
COPY deps/toolchain.mk /tmp/toolchain.mk
RUN set -eu; \
    mkdir -p /opt/vendor; \
    make -f /tmp/toolchain.mk VENDOR=/opt/vendor /opt/vendor/spinel/spinel /opt/vendor/spinelkit/spinel_kit.rb; \
    rm /tmp/toolchain.mk; \
    chown -R runner:runner /opt/vendor

# The entrypoint starts as root and drops to runner itself.
WORKDIR /home/runner
ENTRYPOINT ["/entrypoint.sh"]
