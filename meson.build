project(
  'pixiewood-android-sysroot',
  'c',
  version: '0.1.0',
  meson_version: '>=1.3.0',
  default_options: ['c_std=gnu11'],
)

# Every dependency() below is one the Android GTK distro publishes.
# Meson builds the wraps and `meson install` publishes headers, shared
# libraries, and pkg-config files into the sysroot. This probe is not installed.
gtk_dep = dependency('gtk4')
deps = [
  dependency('glib-2.0'),
  dependency('gobject-2.0'),
  dependency('gio-2.0'),
  dependency('gmodule-2.0'),
  dependency('cairo'),
  dependency('cairo-gobject'),
  dependency('pango'),
  dependency('pangocairo'),
  dependency('harfbuzz'),
  dependency('fontconfig'),
  dependency('gdk-pixbuf-2.0'),
  gtk_dep,
  dependency('libadwaita-1'),
  dependency('gtksourceview-5'),
  dependency('libxml-2.0'),
  dependency('sqlite3'),
  dependency('gee-0.8'),
  dependency('json-glib-1.0'),
  dependency('libnghttp2'),
  dependency('libsoup-3.0'),
  dependency('libcrypto'),
  dependency('libssl'),
  dependency('libpsl'),
  dependency('webkitgtk-android-1'),
]

# glib-networking exposes gioopenssl only after its subproject has run
# override_dependency(). Apps link that static module the same way.
subproject('glib-networking')
deps += dependency('gioopenssl')

executable(
  'pixiewood-sysroot-probe',
  'probe.c',
  dependencies: deps,
  install: false,
)
