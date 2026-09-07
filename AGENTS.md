
## Commit Messages

1. Commit messages must be written in English.

## Landscape Release Versions

1. Version tags WITHOUT the `v` prefix (e.g. `0.24.0`, `0.20.1-1`) in the
   [landscape](https://github.com/ThisSeanZhang/landscape) repository are NOT
   official releases. Ignore them.
2. Version fields in config files (`LANDSCAPE_VERSION` in `build.env`, and the
   `version` field in `userpatches/overlay/landscape_init-*.toml`) must only
   ever be set to an official release version (i.e. a `v`-prefixed tag, such
   as `v0.24.2`).
