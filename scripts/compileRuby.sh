#!/bin/bash

touch /home/mastodon/.bashrc

echo "Cloning rbenv..."
git clone https://github.com/rbenv/rbenv.git /home/mastodon/.rbenv

echo 'export PATH="/home/mastodon/.rbenv/bin:$PATH"' >> /home/mastodon/.bashrc
echo 'eval "$(rbenv init - bash)"' >> /home/mastodon/.bashrc

rbenv init - bash

echo "Cloning ruby-build..."
git clone https://github.com/rbenv/ruby-build.git /home/mastodon/.rbenv/plugins/ruby-build

cd /home/mastodon/.rbenv

echo "Compiling and installing Ruby ${RUBY_INSTALL_VERSION}..."
RUBY_CONFIGURE_OPTS=--with-jemalloc rbenv install ${RUBY_INSTALL_VERSION}
rbenv global ${RUBY_INSTALL_VERSION}
gem install bundler --no-document