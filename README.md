# renderer

This is a PG Renderer derived from the WeBWorK2 codebase
* https://github.com/openwebwork/WeBWorK2

### DOCKER CONTAINER ###

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

* Dockerfile lists perl dependencies
* clone PG and webwork-open-problem-library into the provided stubs ./lib/PG and ./webwork-open-problem-library
    `git clone https://github.com/openwebwork/pg ./lib/PG`
    `git clone https://github.com/openwebwork/webwork-open-problem-library ./webwork-open-problem-library`
* change ./lib/WeBWorK/conf/site.conf line 205 and defaults.config line 1077 to the location of PG
* start the app with morbo -l http://localhost:3000 ./script/render_app
* access on localhost:3000

### API ENDPOINTS ###

Point at localhost:3000/rendered  
Params:
* sourceFilePath (beginning with Library or Contrib will be modified automatically)
* problemSeed (for consistent randomization)
* template (simple or standard)
* format (html or json)
* formURL 
