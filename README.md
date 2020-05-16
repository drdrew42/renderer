# renderer

This is a PG Renderer derived from the WeBWorK2 codebase
* https://github.com/openwebwork/WeBWorK2

### DOCKER CONTAINER ###

MOUNT the openwebwork/webwork-open-problem-library repo at:
    /usr/app/webwork-open-problem-library

* CLONE https://github.com/openwebwork/webwork-open-problem-library

MOUNT the openwebwork/pg repository at:
    /usr/app/lib/PG

* CLONE https://github.com/openwebwork/pg

```
mkdir volumes
mkdir container
git clone https://github.com/openwebwork/pg volumes/PG
git clone https://github.com/openwebwork/webwork-open-problem-library volumes/webwork-open-problem-library
git clone https://github.com/rederly/renderer container/
docker build --tag renderer:1.0 ./container

docker run -d \
  --publish 3000:3000 \
  --mount type=bind,source="$(pwd)"/volumes/PG,target=/usr/app/lib/PG \
  --mount type=bind,source="$(pwd)"/volumes/webwork-open-problem-library/,target=/usr/app/webwork-open-problem-library \
  renderer:1.0
```

### LOCAL INSTALL ###
If using a local install instead of docker:
* clone PG and webwork-open-problem-library into the provided stubs ./lib/PG and ./webwork-open-problem-library
* change ./lib/WeBWorK/conf/site.conf line 205 and defaults.config line 1077 to the location of PG
* begin the app with morbo ./script/render_app and access on localhost:3000
