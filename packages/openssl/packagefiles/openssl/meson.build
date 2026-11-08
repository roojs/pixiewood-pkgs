project(
  'openssl',
  'c',
  version: '3.0.8',
  license: 'Apache-2.0',
  meson_version: '>= 0.55',
  default_options: ['warning_level=1'],
)

include_directories = [
  'include',
  'crypto',
  'crypto/modes',
  'crypto/ec/curve448',
  'crypto/ec/curve448/arch_32',
  'providers/common/include',
  'providers/implementations/include',
]

compiler = meson.get_compiler('c')

dependencies = [
  # TODO: Make this optionally added once we have threading configurable via options
  dependency('threads'),
]
defines = [
  # Compile out hardware engines. Most are stubs that dynamically load
  # the real driver but that poses a security liability when an attacker
  # is able to create a malicious DLL in one of the default search paths.
  'OPENSSL_NO_HW',
]
c_args = []

asm_opt = get_option('asm')

if asm_opt.disabled()
  gas_or_nasm = false
else
  gas_or_nasm = (find_program(
    'as',
    required: false,
  ).found() or
find_program(
    'nasm',
    required: false,
  ).found()
)
endif

if host_machine.system() not in ['linux', 'android']
  error('This OpenSSL package is for Android: ' + host_machine.system())
endif

# cpu family -> generated OpenSSL target. Android uses the Linux configs.
openssl_arch = {
  'aarch64': 'linux-aarch64',
  'x86_64': 'linux-x86_64',
}
arch_subdir = openssl_arch.get(host_machine.cpu_family(), '')
if arch_subdir == ''
  error('Unsupported arch for this OpenSSL package: ' + host_machine.cpu_family())
endif

if gas_or_nasm
  asm = 'asm'
  message('OpenSSL is configured with ASM support')
elif asm_opt.enabled()
  error('Neither GNU Assembler nor Netwide Assembler were found, cannot use "asm=enabled" option')
else
  asm = 'no-asm'
  defines += ['OPENSSL_NO_ASM']
  message('OpenSSL is configured without ASM support')
endif

subdir('generated-config/archs' / arch_subdir / asm)

# Android uses the Linux OpenSSL paths.
defines += [
  'OPENSSLDIR="/etc/ssl"',
  'ENGINESDIR="/dev/null"',
  'MODULESDIR="/dev/null"',
]
c_args += ['-Wno-missing-field-initializers']
if compiler.get_id() != 'clang'
  c_args += ['-Wno-old-style-declaration']
endif

foreach library : openssl_libraries
  # MSVC fails with "ERROR: C static library 'ws2_32' not found" when `static` is specified at all
  if compiler.get_id() == 'msvc'
    dependencies += [compiler.find_library(library)]
  else
    dependencies += [
      compiler.find_library(
        library,
        static: get_option('default_library') == 'static',
      ),
    ]
  endif
endforeach

# We may need to add some defines for static builds
if get_option('default_library') == 'static'
  defines += [
    'OSSL_CRYPTO_DSO_CONF_H',
    'DSO_NONE',
    'DSO_EXTENSION=".so"',
    'OPENSSL_NO_DSO',
  ]
endif

foreach define : defines + openssl_defines
  c_args += ['-D' + define]
endforeach

c_args += openssl_cflags

include_directories += openssl_include_directories

libcrypto_lib = library(
  'crypto',
  dependencies: dependencies,
  sources: libcrypto_sources,
  include_directories: include_directories,
  c_args: c_args,
  vs_module_defs: 'crypto.def',
  install: true,
)

libcrypto_dep = declare_dependency(
  include_directories: include_directories,
  dependencies: dependencies,
  link_with: libcrypto_lib,
)

libssl_lib = library(
  'ssl',
  dependencies: dependencies + [libcrypto_dep],
  sources: libssl_sources,
  include_directories: include_directories,
  c_args: c_args,
  vs_module_defs: 'ssl.def',
  install: true,
)

libssl_dep = declare_dependency(
  include_directories: include_directories,
  dependencies: dependencies + [libcrypto_dep],
  link_with: libssl_lib,
)

openssl_dep = declare_dependency(
  dependencies: [libcrypto_dep, libssl_dep],
)

# A prebuilt package is found with pkg-config. The subproject dependency
# variables above are only visible inside this Meson build.
pkg = import('pkgconfig')
pkg.generate(
  libcrypto_lib,
  name: 'libcrypto',
  description: 'OpenSSL cryptography library',
)
pkg.generate(
  libssl_lib,
  name: 'libssl',
  description: 'OpenSSL SSL and TLS library',
  requires: ['libcrypto'],
)
pkg.generate(
  name: 'openssl',
  description: 'OpenSSL',
  requires: ['libssl', 'libcrypto'],
)
# meson.add_install_script is the function this Meson provides. The openssl
# project declares meson_version >= 0.55, which hides the newer free function.
meson.add_install_script(
  'install-headers.sh',
  meson.current_source_dir() / 'generated-config' / 'archs' / arch_subdir / asm / 'include' / 'openssl',
  meson.current_source_dir() / 'include' / 'openssl',
)

openssl_cli_directories = include_directories + ['apps/include']

cli_opt = get_option('build_cli')

openssl_cli = executable(
  'openssl',
  build_by_default: cli_opt,
  dependencies: dependencies + [openssl_dep],
  sources: openssl_cli_sources,
  include_directories: openssl_cli_directories,
  c_args: c_args,
  install: cli_opt,
)
