# libadwaita VAPI vendored instead of generated on CI

**Status:** vendored workaround in tree; CI generation deferred

## Problem

- Published `libadwaita` pixies had no `share/vala/vapi/libadwaita-1.vapi`.
- `vapi-stage.sh` used host `g-ir-scanner` against the Android install; CI failed (`--includes`, missing `Gio-2.0.gir`, no runnable Android ELF on the host).

## Workaround

- `packages/libadwaita/vapi/libadwaita-1.vapi` is checked in.
- `vapi-stage.sh` copies it into each libadwaita pixie destdir after `meson install`.
- Refresh the vendored file when `libadwaita.wrap` `revision` changes (regenerate on a host with matching libadwaita, or replace from upstream VAPI).

## Follow-up

- Proper cross/GI story for gtk, libadwaita, and gtksourceview if we outgrow the vendored API.