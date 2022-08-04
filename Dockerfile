FROM ubuntu:20.04
LABEL org.opencontainers.image.source=https://github.com/openwebwork/renderer

WORKDIR /usr/app
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York

RUN apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
    apt-utils \
    git \
    gcc \
    make \
    curl \
    dvipng \
    openssl \
    libc-dev \
    cpanminus \
    libssl-dev \
    libgd-perl \
    zlib1g-dev \
    imagemagick \
    libdbi-perl \
    libjson-perl \
    libcgi-pm-perl \
    libjson-xs-perl \
    ca-certificates \
    libstorable-perl \
    libdatetime-perl \
    libuuid-tiny-perl \
    libtie-ixhash-perl \
    libhttp-async-perl \
    libnet-ssleay-perl \
    libarchive-zip-perl \
    libcrypt-ssleay-perl \
    libclass-accessor-perl \
    libstring-shellquote-perl \
    libextutils-cbuilder-perl \
    libproc-processtable-perl \
    libmath-random-secure-perl \
    libdata-structure-util-perl \
    liblocale-maketext-lexicon-perl \
    libyaml-libyaml-perl \
    && curl -fsSL https://deb.nodesource.com/setup_16.x | bash - \
    && apt-get install -y --no-install-recommends --no-install-suggests nodejs \
    && apt-get clean \
    && rm -fr /var/lib/apt/lists/* /tmp/*

RUN cpanm install Mojo::Base Statistics::R::IO::Rserve Date::Format Future::AsyncAwait Crypt::JWT IO::Socket::SSL CGI::Cookie \
    && rm -fr ./cpanm /root/.cpanm /tmp/*

COPY . .

RUN cp render_app.conf.dist render_app.conf

RUN cp conf/pg_config.yml lib/PG/conf/pg_config.yml

RUN npm install

RUN cd lib/PG/htdocs && npm install && cd ../../..

EXPOSE 3000

HEALTHCHECK CMD curl -I localhost:3000/health

CMD hypnotoad -f ./script/render_app
