FROM docker.io/library/ubuntu:22.04 AS os-base

SHELL ["/bin/bash", "-lc"]

ARG OS_BUILD_SEED

# Set the frontend to noninteractive to prevent tzdata from hanging during install
# and set the version of Ruby to install.
ENV DEBIAN_FRONTEND=noninteractive \
    RUBY_INSTALL_VERSION=3.0.6

RUN ln -fs /usr/share/zoneinfo/America/New_York /etc/localtime

# Run apt update and upgrade to ensure the latest packages are installed.
RUN apt-get update ; \
    apt-get upgrade -y

# Install core dependencies.
RUN apt-get install -y \
                curl \
                wget \
                gnupg \
                apt-transport-https \
                lsb-release ca-certificates \
                git

# Set up the NodeSource repository.
RUN curl -sL https://deb.nodesource.com/setup_16.x | bash -

# Install the rest of the dependencies required to build Mastodon.
RUN apt-get install -y \
                imagemagick \
                ffmpeg \
                libpq-dev \
                libxml2-dev \
                libxslt1-dev \
                file git-core \
                g++ \
                libprotobuf-dev \
                protobuf-compiler \
                pkg-config \
                nodejs \
                gcc \
                autoconf \
                bison \
                build-essential \
                libssl-dev \
                libyaml-dev \
                libreadline6-dev \
                zlib1g-dev \
                libncurses5-dev \
                libffi-dev \
                libgdbm-dev \
                libidn11-dev \
                libicu-dev \
                libjemalloc-dev \
                tini

RUN corepack enable ; \
    yarn set version classic

# Create a user named 'mastodon' to run Mastodon as.
RUN adduser --disabled-login mastodon

# Switch to the 'mastodon' user and set up its environment.
USER mastodon
RUN touch /home/mastodon/.bashrc
SHELL ["/bin/bash", "-lc"]
ENV PATH="/home/mastodon/.rbenv/bin:/home/mastodon/.rbenv/versions/${RUBY_INSTALL_VERSION}/bin:$PATH"

# Install rbenv.
RUN git clone https://github.com/rbenv/rbenv.git /home/mastodon/.rbenv ; \
    echo 'export PATH="/home/mastodon/.rbenv/bin:$PATH"' >> /home/mastodon/.bashrc \
    echo 'eval "$(rbenv init - bash)"' >> /home/mastodon/.bashrc ; \
    exec bash

# Install ruby-build and install Ruby.
RUN git clone https://github.com/rbenv/ruby-build.git /home/mastodon/.rbenv/plugins/ruby-build ; \
    cd /home/mastodon/.rbenv ; \
    RUBY_CONFIGURE_OPTS=--with-jemalloc rbenv install ${RUBY_INSTALL_VERSION} ; \
    rbenv global ${RUBY_INSTALL_VERSION} ; \
    gem install bundler --no-document

FROM os-base AS mastodon-app
ARG BUILD_SEED

# Set the working directory to '/mastodon' and clone the Mastodon Glitch repository.
WORKDIR /mastodon
RUN git clone https://github.com/glitch-soc/mastodon.git /mastodon

RUN git clone --branch "mastodon-nightly" https://github.com/ronilaukkarinen/mastodon-bird-ui.git /tmp/mastodon-bird-ui

COPY --chown=mastodon:mastodon ./patches/mastodon-bird-ui/ /tmp/mastodon-bird-ui-patches/

WORKDIR /tmp/mastodon-bird-ui

RUN git config user.name "ContainerBuild" ; \
    git config user.email "build@localhost" ; \
    git am /tmp/mastodon-bird-ui-patches/0001-Add-modifications-for-OCW.Social.patch

WORKDIR /mastodon

RUN mkdir /mastodon/app/javascript/styles/elephant ; \
    cp /tmp/mastodon-bird-ui/layout-multiple-columns.css /mastodon/app/javascript/styles/elephant/layout-multiple-columns.scss ; \
    cp /tmp/mastodon-bird-ui/layout-single-column.css /mastodon/app/javascript/styles/elephant/layout-single-column.scss ; \
    rm -rf /tmp/mastodon-bird-ui ; \
    rm -rf /tmp/mastodon-bird-ui-patches

# Copy Bird UI theme files to /mastodon/app/javascript/styles.
COPY ./themes/styles/elephant.scss /mastodon/app/javascript/styles/elephant.scss
COPY ./themes/styles/elephant-light.scss /mastodon/app/javascript/styles/elephant-light.scss
COPY ./themes/styles/elephant-contrast.scss /mastodon/app/javascript/styles/elephant-contrast.scss

# Copy Bird UI theme files to /mastodon/app/javascript/skins/vanilla.
COPY ./themes/vanilla/elephant/ /mastodon/app/javascript/skins/vanilla/elephant/
COPY ./themes/vanilla/elephant-light/ /mastodon/app/javascript/skins/vanilla/elephant-light/
COPY ./themes/vanilla/elephant-contrast/ /mastodon/app/javascript/skins/vanilla/elephant-contrast/

# Install the required gems and JavaScript packages.
RUN bundle config deployment "true" ; \
    bundle config without "development test" ; \
    bundle install -j$(getconf _NPROCESSORS_ONLN) ; \
    yarn install --pure-lockfile

# Set the necessary environment variables for precompiling assets.
ENV RAILS_ENV="production" \
    NODE_ENV="production" \
    RAILS_SERVE_STATIC_FILES="true" \
    BIND="0.0.0.0"

# Precompile the assets.
RUN OTP_SECRET=precompile_placeholder SECRET_KEY_BASE=precompile_placeholder bundle exec rails assets:precompile && \
    yarn cache clean

LABEL org.opencontainers.image.source=https://github.com/ocw-social/ocw-social
LABEL org.opencontainers.image.description="Container image for the OCW Social Mastodon server."

ENTRYPOINT ["/usr/bin/tini", "--"]
EXPOSE 3000 4000