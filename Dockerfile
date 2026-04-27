# Stage 1: Builder — install all build tools, compile Perl XS modules, generate JS/CSS assets
FROM ubuntu:24.04 AS builder
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
    dvisvgm \
    pdf2svg \
    preview-latex-style \
    texlive \
    texlive-latex-extra \
    texlive-plain-generic \
    texlive-science \
    texlive-xetex \
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
    && curl -fsSL https://deb.nodesource.com/setup_22.x | bash - \
    && apt-get install -y --no-install-recommends --no-install-suggests nodejs \
    && apt-get clean \
    && rm -fr /var/lib/apt/lists/* /tmp/*

COPY cpanfile .
RUN cpanm --notest --installdeps . \
    && rm -fr ./cpanm /root/.cpanm /tmp/*

COPY . .

RUN cp renderer.conf.dist renderer.conf

RUN cp conf/pg_config.yml lib/PG/conf/pg_config.yml

# Install all npm deps (including devDependencies for asset generation),
# then prune to production-only for the runtime image.
RUN cd public/ && npm install && npm prune --omit=dev && cd ..

RUN cd lib/PG/htdocs && npm install && npm prune --omit=dev && cd ../../..

# Stage 2: Runtime — only what's needed to serve requests
FROM ubuntu:24.04

LABEL org.opencontainers.image.source=https://github.com/openwebwork/renderer

WORKDIR /usr/app
ARG DEBIAN_FRONTEND=noninteractive
ENV TZ=America/New_York

RUN apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
    apt-utils \
    curl \
    dvipng \
    openssl \
    libgd-perl \
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
    libproc-processtable-perl \
    libmath-random-secure-perl \
    libdata-structure-util-perl \
    liblocale-maketext-lexicon-perl \
    libyaml-libyaml-perl \
    && apt-get clean \
    && rm -fr /var/lib/apt/lists/* /tmp/*

# Copy cpanm-installed Perl modules (XS .so + pure Perl) and Mojo binaries.
# Copies all of /usr/local/ to stay architecture-independent (avoids hardcoding aarch64/x86_64 paths).
COPY --from=builder /usr/local /usr/local

# Copy the full app tree (includes pruned node_modules and generated assets)
COPY --from=builder /usr/app /usr/app

# Renderer version — populated at build time from `git describe --always --dirty
# --abbrev=8 --tags` on the build host. Surfaces in /health and is forwarded to
# OPL on registration so consumers know which renderer build is talking to them.
# Defaults to 'unknown' when the build was launched without --build-arg.
ARG RENDERER_VERSION=unknown
ENV RENDERER_VERSION=${RENDERER_VERSION}

EXPOSE 3000

HEALTHCHECK CMD curl -I localhost:3000/health

# RSERVE_HOST env var overrides pg_config.yml default (webwork-rserve) at startup.
# Used for AWS service discovery hostnames (rserve.webwork.{env}.local).
CMD if [ -n "$RSERVE_HOST" ]; then \
      sed -i "s/host: webwork-rserve/host: $RSERVE_HOST/" lib/PG/conf/pg_config.yml; \
    fi && \
    hypnotoad -f ./script/renderer
