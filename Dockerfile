FROM ubuntu:18.04
MAINTAINER Rederly

WORKDIR /usr/app

ENV APP_ROOT=/usr/app

ENV WEBWORK_ROOT=$APP_ROOT/lib/WeBWorK \
    PG_ROOT=$APP_ROOT/lib/pg

RUN apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
    apt-utils \
    curl \
  	dvipng \
  	gcc \
    make \
    libgd-perl \
    cpanminus \
    libstring-shellquote-perl \
    libproc-processtable-perl \
    libdatetime-perl \
    libdbi-perl \
    libtie-ixhash-perl \
    libuuid-tiny-perl \
    libjson-perl \
    liblocale-maketext-lexicon-perl \
    libclass-accessor-perl \
    libcgi-pm-perl \
    && apt-get clean \
    && rm -fr /var/lib/apt/lists/* /tmp/*

RUN cpanm install Mojolicious Date::Format \
    && rm -fr ./cpanm /root/.cpanm /tmp/*

COPY . .

EXPOSE 3000

CMD morbo ./script/render_app
