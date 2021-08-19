
- Go to the location under which the renderer was installed.
- You need to have `xgettext.pl` installed.

```
cd container/lib
xgettext.pl -o WeBWorK/lib/WeBWorK/Localize/standalone.pot -D PG/lib -D PG/macros -D RenderApp -D WeBWorK/lib RenderApp.pm
```

- That creates the POT file of all strings found

```
cd WeBWorK/lib/WeBWorK/Localize
find . -name '*.po' -exec bash -c "echo \"Updating {}\"; msgmerge -qUN {} standalone.pot" \;
```

