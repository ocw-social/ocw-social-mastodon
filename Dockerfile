ARG TARGETPLATFORM=${TARGETPLATFORM}
ARG BUILDPLATFORM=${BUILDPLATFORM}

# Ruby image to use for base image.
ARG RUBY_VERSION="3.3.2"
# # Node version to use in base image.
ARG NODE_MAJOR="20"
# Debian image to use for base image.
ARG DEBIAN_VERSION="bookworm"

FROM --platform=${TARGETPLATFORM} docker.io/node:${NODE_MAJOR}-${DEBIAN_VERSION}-slim as node
FROM --platform=${TARGETPLATFORM} docker.io/ruby:${RUBY_VERSION}-slim-${DEBIAN_VERSION} as ruby

ARG RAILS_SERVE_STATIC_FILES="true"
ARG RUBY_YJIT_ENABLE="1"

ARG UID="991"
ARG GID="991"

# Set the frontend to noninteractive to prevent tzdata from hanging during install
# and set the version of Ruby to install.
ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_MAJOR=${NODE_MAJOR}

ENV RAILS_SERVE_STATIC_FILES=${RAILS_SERVE_STATIC_FILES}
ENV RUBY_YJIT_ENABLE=${RUBY_YJIT_ENABLE}

ENV BIND="0.0.0.0"
ENV NODE_ENV="production"
ENV RAILS_ENV="production"
ENV PATH="${PATH}:/opt/ruby/bin:/opt/mastodon/bin"
ENV MALLOC_CONF="narenas:2,background_thread:true,thp:never,dirty_decay_ms:1000,muzzy_decay_ms:0"

RUN groupadd -g ${GID} mastodon && \
    useradd -l -u "${UID}" -g "${GID}" -m -d /opt/mastodon mastodon && \
    ln -s /opt/mastodon /mastodon

WORKDIR /opt/mastodon

# Set timezone to EST/EDT, update installed packages,
# setup NodeSource for NodeJS, install all required packages,
# and add the 'mastodon' user.
RUN echo "Etc/UTC" > /etc/localtime && \
    apt-get update && \
    apt-get dist-upgrade -y && \
    apt-get install -y curl gnupg apt-transport-https lsb-release ca-certificates git && \
    mkdir -p /etc/apt/keyrings && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ffmpeg \
        file \
        imagemagick \
        libjemalloc2 \
        patchelf \
        procps \
        tini \
        tzdata \
        wget \
        g++ \
        gcc \
        git \
        libgdbm-dev \
        libgmp-dev \
        libicu-dev \
        libidn-dev \
        libpq-dev \
        libssl-dev \
        make \
        shared-mime-info \
        zlib1g-dev \
        libssl3 \
        libpq5 \
        libicu72 \
        libidn12 \
        libreadline8 \
        libyaml-0-2 && \
    patchelf --add-needed libjemalloc.so.2 /usr/local/bin/ruby && \
    apt-get purge -y patchelf && \
    apt-get autoremove -y && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

FROM --platform=${TARGETPLATFORM} ruby as build

COPY --from=node /usr/local/bin /usr/local/bin
COPY --from=node /usr/local/lib /usr/local/lib

WORKDIR /opt/mastodon

RUN rm .profile && \
    git config --global --add safe.directory /opt/mastodon && \
    git config --global init.defaultBranch main && \
    git init && \
    git remote add origin https://github.com/glitch-soc/mastodon.git && \
    git pull origin main

RUN rm /usr/local/bin/yarn* ; \
    corepack enable && \
    corepack prepare --activate

FROM --platform=${TARGETPLATFORM} build as bundler

WORKDIR /opt/mastodon

RUN bundle config set --global frozen "true" && \
    bundle config set --global cache_all "false" && \
    bundle config set --local without "development test" && \
    bundle config set silence_root_warning "true" && \
    bundle install -j"$(nproc)"

FROM --platform=${TARGETPLATFORM} build as yarn

WORKDIR /opt/mastodon

RUN yarn workspaces focus --production @mastodon/mastodon

FROM --platform=${TARGETPLATFORM} build as precompiler

COPY --from=yarn /opt/mastodon /opt/mastodon/
COPY --from=bundler /opt/mastodon /opt/mastodon/
COPY --from=bundler /usr/local/bundle/ /usr/local/bundle/

RUN ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY=precompile_placeholder \
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT=precompile_placeholder \
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY=precompile_placeholder \
    OTP_SECRET=precompile_placeholder \
    SECRET_KEY_BASE=precompile_placeholder \
    bundle exec rails assets:precompile && \
    rm -rf /opt/mastodon/tmp

FROM --platform=${TARGETPLATFORM} ruby as mastodon

WORKDIR /opt/mastodon

RUN rm .profile && \
    git config --global --add safe.directory /opt/mastodon && \
    git config --global init.defaultBranch main && \
    git init && \
    git remote add origin https://github.com/glitch-soc/mastodon.git && \
    git pull origin main && \
    rm -rf /opt/mastodon/.git && \
    mkdir -p /opt/mastodon/public/system && \
    chown mastodon:mastodon /opt/mastodon/public/system && \
    mkdir -p /opt/mastodon/tmp && \
    chown -R mastodon:mastodon /opt/mastodon/tmp

WORKDIR /opt/mastodon

COPY --from=precompiler /opt/mastodon/public/packs /opt/mastodon/public/packs
COPY --from=precompiler /opt/mastodon/public/assets /opt/mastodon/public/assets
COPY --from=bundler /usr/local/bundle/ /usr/local/bundle/

RUN bundle exec bootsnap precompile --gemfile app/ lib/

USER mastodon
EXPOSE 3000 4000
ENTRYPOINT ["/usr/bin/tini", "--"]
