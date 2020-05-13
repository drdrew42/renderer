# renderer
This is a PG Renderer derived from the WeBWorK2 codebase
* https://github.com/openwebwork/WeBWorK2

clone the openwebwork/webwork-open-problem-library repo into the corresponding folder at the root of this project
(an even better plan would mount the repository as a volume)
* https://github.com/openwebwork/webwork-open-problem-library

clone (or mount) the openwebwork/pg repository into lib/PG
* https://github.com/openwebwork/pg

begin the app with morbo ./script/render_app and access on localhost:3000

CPAN dependencies:
Mojo::Base
