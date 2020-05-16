# renderer
This is a PG Renderer derived from the WeBWorK2 codebase
* https://github.com/openwebwork/WeBWorK2

MOUNT the openwebwork/webwork-open-problem-library repo at:
    /usr/app/webwork-open-problem-library

* https://github.com/openwebwork/webwork-open-problem-library

MOUNT the openwebwork/pg repository at:
    /usr/app/lib/PG

* https://github.com/openwebwork/pg

begin the app with morbo ./script/render_app and access on localhost:3000

If local install instead of docker, change ./lib/WeBWorK/conf/site.conf line 205 and defaults.config line 1077
