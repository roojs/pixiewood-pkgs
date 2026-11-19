project(
  'freerdp',
  'c',
  version: '3.33.1',
  meson_version: '>=1.3.0',
  license: 'Apache-2.0',
)

# FreeRDP ships CMake, not Meson. The script below drives the NDK toolchain
# and stages headers, shared libraries, and pkg-config files. The .pc version
# is the one from the upstream tarball. These libraries link the OpenSSL
# already in the dependency sysroot, so a nested OpenSSL wrap is not used.
cc = meson.get_compiler('c')
ssl = dependency('libssl', allow_fallback: false)
crypto = dependency('libcrypto', allow_fallback: false)
cairo = dependency('cairo', required: false, allow_fallback: false)
cairo_flag = cairo.found() ? 'ON' : 'OFF'

linkdir = meson.current_build_dir() / 'link'
stamp = custom_target(
  'freerdp-android',
  input: files('android-cmake.sh'),
  output: 'freerdp-android.stamp',
  command: [
    find_program('bash'),
    '@INPUT@',
    meson.current_source_dir(),
    meson.current_build_dir() / 'cmake',
    meson.current_build_dir() / 'stage',
    linkdir,
    cc.cmd_array()[0],
    ssl.get_variable(pkgconfig: 'prefix'),
    ssl.get_variable(pkgconfig: 'libdir'),
    cairo_flag,
    '@OUTPUT@',
  ],
  console: true,
)

winpr_lib = custom_target(
  'winpr3',
  output: 'libwinpr3.so',
  command: [find_program('cp'), '-L', linkdir / 'libwinpr3.so', '@OUTPUT@'],
  depends: stamp,
)
freerdp_lib = custom_target(
  'freerdp3',
  output: 'libfreerdp3.so',
  command: [find_program('cp'), '-L', linkdir / 'libfreerdp3.so', '@OUTPUT@'],
  depends: stamp,
)
client_lib = custom_target(
  'freerdp-client3',
  output: 'libfreerdp-client3.so',
  command: [find_program('cp'), '-L', linkdir / 'libfreerdp-client3.so', '@OUTPUT@'],
  depends: stamp,
)
server_lib = custom_target(
  'freerdp-server3',
  output: 'libfreerdp-server3.so',
  command: [find_program('cp'), '-L', linkdir / 'libfreerdp-server3.so', '@OUTPUT@'],
  depends: stamp,
)

winpr_dep = declare_dependency(
  link_with: winpr_lib,
  dependencies: [crypto],
  version: meson.project_version(),
)
freerdp_deps = [winpr_dep, ssl, crypto]
if cairo.found()
  freerdp_deps += cairo
endif
freerdp_dep = declare_dependency(
  link_with: freerdp_lib,
  dependencies: freerdp_deps,
  version: meson.project_version(),
)
client_dep = declare_dependency(
  link_with: client_lib,
  dependencies: [freerdp_dep],
  version: meson.project_version(),
)
server_dep = declare_dependency(
  link_with: server_lib,
  dependencies: [freerdp_dep],
  version: meson.project_version(),
)

meson.override_dependency('winpr3', winpr_dep)
meson.override_dependency('freerdp3', freerdp_dep)
meson.override_dependency('freerdp-client3', client_dep)
meson.override_dependency('freerdp-server3', server_dep)

meson.add_install_script(
  files('install-tree.sh'),
  meson.current_build_dir() / 'stage',
)
