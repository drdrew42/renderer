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
docker build --tag renderer:1.0 .

docker run -d \
  --publish 3000:3000 \
  --mount type=bind,source="$(pwd)"/PG,target=/usr/app/lib/PG \
  --mount type=bind,source="$(pwd)"/webwork-open-problem-library/,target=/usr/app/webwork-open-problem-library \
  renderer:1.0
```

### LOCAL INSTALL ###
If using a local install instead of docker, change ./lib/WeBWorK/conf/site.conf line 205 and defaults.config line 1077

begin the app with morbo ./script/render_app and access on localhost:3000
