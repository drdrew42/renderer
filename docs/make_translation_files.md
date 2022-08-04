# How to generate translation files

- Go to the location under which the renderer was installed.
- You need to have `xgettext.pl` installed.
- This assumes that you are starting in the directory of the renderer clone.

```bash
cd lib
xgettext.pl -o WeBWorK/Localize/standalone.pot -D PG/lib -D PG/macros -D RenderApp -D WeBWorK RenderApp.pm
```

- That creates the POT file of all strings found

```bash
cd WeBWorK/Localize
find . -name '*.po' -exec bash -c "echo \"Updating {}\"; msgmerge -qUN {} standalone.pot" \;
```

