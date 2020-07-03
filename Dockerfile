FROM ubuntu:18.04
MAINTAINER Rederly

WORKDIR /usr/app

ENV RENDER_ROOT=/usr/app

ENV WEBWORK_ROOT=$RENDER_ROOT/lib/WeBWorK \
    PG_ROOT=$RENDER_ROOT/lib/PG

RUN apt-get update \
    && apt-get install -y --no-install-recommends --no-install-suggests \
    apt-utils \
  	gcc \
    make \
    curl \
  	dvipng \
    cpanminus \
    libgd-perl \
    libdbi-perl \
    libjson-perl \
    libcgi-pm-perl \
    libjson-xs-perl \
    libstorable-perl \
    libdatetime-perl \
    libuuid-tiny-perl \
    libtie-ixhash-perl \
    libclass-accessor-perl \
    libstring-shellquote-perl \
    libproc-processtable-perl \
    libdata-structure-util-perl \
    liblocale-maketext-lexicon-perl \
    && apt-get clean \
    && rm -fr /var/lib/apt/lists/* /tmp/*

RUN cpanm install Mojo::Base Date::Format \
    && rm -fr ./cpanm /root/.cpanm /tmp/*

COPY . .

RUN cp render_app.conf.dist render_app.conf

EXPOSE 3000

CMD morbo ./script/render_app
