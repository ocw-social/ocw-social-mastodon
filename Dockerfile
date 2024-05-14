FROM docker.io/library/ubuntu:22.04 AS os-base

ARG OS_BUILD_SEED

# Set the frontend to noninteractive to prevent tzdata from hanging during install
# and set the version of Ruby to install.
ENV DEBIAN_FRONTEND=noninteractive
ENV NODE_MAJOR=20

# Set timezone to EST/EDT, update installed packages,
# setup NodeSource for NodeJS, install all required packages,
# and add the 'mastodon' user.
RUN ln -fs /usr/share/zoneinfo/America/New_York /etc/localtime ; \
    apt-get update ; \
    apt-get upgrade -y ; \
    apt-get install -y curl wget gnupg apt-transport-https lsb-release ca-certificates git ; \
    mkdir -p /etc/apt/keyrings ; \
    curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg ; \
    echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${NODE_MAJOR}.x nodistro main" | tee /etc/apt/sources.list.d/nodesource.list ; \
    apt-get update ; \
    apt-get install -y \
    bash \
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
    tini ; \
    apt-get autoremove -y ; \
    apt-get clean ; \
    rm -rf /var/lib/apt/lists/* ;\
    corepack enable ; \
    yarn set version classic ; \
    adduser --disabled-login mastodon

FROM os-base AS ruby-base

# Switch to the 'mastodon' user and set up its environment.
USER mastodon
SHELL ["/bin/bash", "-lc"]
ENV RUBY_INSTALL_VERSION=3.2.2
ENV PATH="/home/mastodon/.rbenv/bin:/home/mastodon/.rbenv/versions/${RUBY_INSTALL_VERSION}/bin:$PATH"

COPY --chown=mastodon:mastodon ./scripts/compileRuby.sh /tmp/compileRuby.sh

RUN chmod +x /tmp/compileRuby.sh && \
    /bin/bash /tmp/compileRuby.sh && \
    rm -f /tmp/compileRuby.sh

FROM ruby-base AS ruby-final
USER mastodon

COPY --from=ruby-base /home/mastodon/.rbenv/bin /home/mastodon/.rbenv/bin
COPY --from=ruby-base /home/mastodon/.rbenv/versions/$RUBY_INSTALL_VERSION/bin /home/mastodon/.rbenv/versions/$RUBY_INSTALL_VERSION/bin

FROM ruby-final AS mastodon-build
ARG BUILD_SEED

USER mastodon

# Set the working directory to '/mastodon' and clone the Mastodon Glitch repository.
WORKDIR /mastodon
RUN git clone https://github.com/glitch-soc/mastodon.git /mastodon

RUN git clone --branch "main" https://github.com/ronilaukkarinen/mastodon-bird-ui.git /tmp/mastodon-bird-ui

COPY --chown=mastodon:mastodon ./patches/mastodon-bird-ui/ /tmp/mastodon-bird-ui-patches/
#COPY --chown=mastodon:mastodon ./patches/glitch-soc/ /tmp/glitch-soc-patches/

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

#RUN git config user.name "ContainerBuild" ; \
#    git config user.email "build@localhost" ; \
#    git am /tmp/glitch-soc-patches/0001-Add-OCW-edition-flavour-files.patch ; \
#    git am /tmp/glitch-soc-patches/0002-Attempting-to-fix-flavour.patch ; \
#    git am /tmp/glitch-soc-patches/0003-Fix-regression-with-sign-in-state.patch ; \
#    git am /tmp/glitch-soc-patches/0004-Fix-for-recent-changes-2024-01-16.patch ; \
#    rm -rf /tmp/glitch-soc-patches

# Copy Bird UI theme files to /mastodon/app/javascript/styles.
COPY ./themes/styles/elephant.scss /mastodon/app/javascript/styles/elephant.scss
COPY ./themes/styles/elephant-light.scss /mastodon/app/javascript/styles/elephant-light.scss
COPY ./themes/styles/elephant-contrast.scss /mastodon/app/javascript/styles/elephant-contrast.scss

# Copy Bird UI theme files to /mastodon/app/javascript/skins/vanilla.
COPY ./themes/vanilla/elephant/ /mastodon/app/javascript/skins/vanilla/elephant/
COPY ./themes/vanilla/elephant-light/ /mastodon/app/javascript/skins/vanilla/elephant-light/
COPY ./themes/vanilla/elephant-contrast/ /mastodon/app/javascript/skins/vanilla/elephant-contrast/

# Install the required gems and JavaScript packages.
RUN bundle config deployment "true" && \
    bundle config without "development test" && \
    bundle install -j$(getconf _NPROCESSORS_ONLN) && \
    yarn install --immutable

# Set the necessary environment variables for precompiling assets.
ENV RAILS_ENV="production" \
    NODE_ENV="production" \
    RAILS_SERVE_STATIC_FILES="true" \
    BIND="0.0.0.0"

# Precompile the assets.
RUN OTP_SECRET=precompile_placeholder SECRET_KEY_BASE=precompile_placeholder bundle exec rails assets:precompile && \
    yarn cache clean

RUN rm -rf /mastodon/.git && \
    rm -rf /mastodon/node_modules

FROM ruby-final AS mastodon-app
USER mastodon

COPY --chown=mastodon:mastodon --from=mastodon-build /mastodon /mastodon

LABEL org.opencontainers.image.source=https://github.com/ocw-social/ocw-social-mastodon
LABEL org.opencontainers.image.description="Container image for the OCW Social Mastodon server."

ENTRYPOINT ["/usr/bin/tini", "--"]
EXPOSE 3000 4000