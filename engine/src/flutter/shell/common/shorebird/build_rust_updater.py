#!/usr/bin/env python3
# Copyright 2024 The Shorebird Authors. All rights reserved.
# Use of this source code is governed by a MIT-style license that can be
# found in the LICENSE file.

"""Build the Rust updater library via cargo, invoked as a GN action."""

import argparse
import base64
import hashlib
import json
import os
import subprocess
import sys


def main():
  parser = argparse.ArgumentParser(description='Build the Rust updater static library.')
  parser.add_argument(
      '--rust-target', required=True, help='Rust target triple (e.g. aarch64-linux-android)'
  )
  parser.add_argument(
      '--manifest-dir', required=True, help='Directory containing the workspace Cargo.toml'
  )
  parser.add_argument(
      '--target-dir',
      required=True,
      help='Cargo target directory; should live inside the GN build output dir',
  )
  parser.add_argument('--output-lib', required=True, help='Expected output library path')
  parser.add_argument('--stamp', required=True, help='Stamp file to write on success')
  parser.add_argument('--ndk-path', help='Path to the Android NDK (required for Android targets)')
  parser.add_argument(
      '--android-api-level', type=int, help='Android API level (required for Android targets)'
  )
  parser.add_argument(
      '--ios-deployment-target',
      help='iOS deployment target (e.g. 13.0); required for *-apple-ios targets',
  )
  parser.add_argument(
      '--mac-deployment-target',
      help='macOS deployment target (e.g. 10.15); required for *-apple-darwin targets',
  )
  parser.add_argument(
      '--security-profile',
      default='legacy',
      help='Compiled security profile: legacy, hardened or hardened-diversified '
      '(GN shorebird_security_profile)',
  )
  parser.add_argument(
      '--toolchain-id', default='', help='sha256:<hex> toolchain identity (GN shorebird_toolchain_id)'
  )
  parser.add_argument(
      '--security-development-exceptions',
      default='false',
      help='true for a development-only hardened updater (loopback HTTP allowed)',
  )
  parser.add_argument(
      '--trust-root-key-id',
      action='append',
      default=[],
      help='Pinned trust-root key ID (repeatable; hardened only)',
  )
  parser.add_argument(
      '--release-root',
      default='',
      help='Release-root pin: base64 canonical release-root payload (required for hardened)',
  )
  parser.add_argument(
      '--release-min-delegations-version',
      default='1',
      help='Lowest release-delegations version the updater accepts (hardened only)',
  )
  parser.add_argument(
      '--diversification-profile',
      default='',
      help='Encoded diversification profile (GN dart_bytecode_profile); '
      'required exactly for hardened-diversified',
  )
  args = parser.parse_args()

  env = os.environ.copy()
  error = _configure_security_env(env, args)
  if error:
    print(f'ERROR: {error}', file=sys.stderr)
    return 1

  is_android = 'android' in args.rust_target
  is_apple_ios = 'apple-ios' in args.rust_target
  is_apple_darwin = 'apple-darwin' in args.rust_target
  is_msvc = 'pc-windows-msvc' in args.rust_target

  if is_android:
    if not args.ndk_path or not args.android_api_level:
      print(
          'ERROR: --ndk-path and --android-api-level are required for '
          'Android targets.',
          file=sys.stderr
      )
      return 1
    _configure_android_env(env, args.rust_target, args.ndk_path, args.android_api_level)

  if is_apple_ios:
    if not args.ios_deployment_target:
      print(
          'ERROR: --ios-deployment-target is required for *-apple-ios targets.',
          file=sys.stderr,
      )
      return 1
    # Setting IPHONEOS_DEPLOYMENT_TARGET makes both the cc crate (compiling
    # transitive C deps like zstd-sys) and rustc's cdylib link step honor
    # the engine's iOS deployment target instead of falling back to their
    # respective defaults (host SDK for cc, target-spec default for rustc).
    env['IPHONEOS_DEPLOYMENT_TARGET'] = args.ios_deployment_target

  if is_apple_darwin:
    if not args.mac_deployment_target:
      print(
          'ERROR: --mac-deployment-target is required for *-apple-darwin targets.',
          file=sys.stderr,
      )
      return 1
    env['MACOSX_DEPLOYMENT_TARGET'] = args.mac_deployment_target

  if is_msvc:
    _configure_msvc_env(env, args.rust_target)

  # GN passes paths relative to the build output dir (which is cwd when
  # Ninja runs the action). Resolve them to absolute paths so they work
  # regardless of cargo's working directory.
  manifest_path = os.path.abspath(os.path.join(args.manifest_dir, 'Cargo.toml'))
  target_dir = os.path.abspath(args.target_dir)
  output_lib = os.path.abspath(args.output_lib)

  cmd = [
      'cargo',
      'build',
      '--release',
      '--target',
      args.rust_target,
      '--manifest-path',
      manifest_path,
      '--target-dir',
      target_dir,
      '-p',
      'updater',
  ]

  print(f'Running: {" ".join(cmd)}', flush=True)
  result = subprocess.run(cmd, env=env)
  if result.returncode != 0:
    print(f'ERROR: cargo build failed with exit code {result.returncode}', file=sys.stderr)
    return result.returncode

  if not os.path.exists(output_lib):
    print(f'ERROR: Expected output library not found: {output_lib}', file=sys.stderr)
    return 1

  # Write stamp file to signal success to Ninja.
  with open(args.stamp, 'w') as f:
    f.write('')

  return 0


_SECURITY_ENV = (
    'SHOREBIRD_SECURITY_PROFILE',
    'SHOREBIRD_TOOLCHAIN_ID',
    'SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS',
    'SHOREBIRD_TRUST_ROOT_KEY_IDS',
    'SHOREBIRD_BUILD_MANIFEST_KEYS',
    'SHOREBIRD_RELEASE_ROOT',
    'SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION',
    'SHOREBIRD_DIVERSIFICATION_PROFILE',
)

_HARDENED_PROFILES = ('hardened', 'hardened-diversified')

# ID of the committed DEVELOPMENT-ONLY diversification profile
# (scripts/testdata/diversification/profile.DEVELOPMENT-ONLY.json); its seed
# is public, so only a development build may use it.
_DEVELOPMENT_DIVERSIFICATION_PROFILE_IDS = (
    'sha256:832856d0bed27833434e3f26b65d03cedc313f9850c2577ca7565c4dc644f46d',
)
_MAX_ENCODED_PROFILE = 8192
_MAX_FIXED_POINTS = 16

# Public key of the committed DEVELOPMENT-ONLY release root
# (scripts/testdata/release-trust/root-1.DEVELOPMENT-ONLY.pem); its private
# half is public, so only a development build may pin it.
_DEVELOPMENT_ROOT_PUBLIC_KEYS = ('iojj3XQJ8ZX9UtstPLpdcspnCb8dlBIb83SIAbQPb1w=',)


def _check_release_root(pin, development_exceptions):
  """Return an error for a pin that is not a contract v2 release-root payload."""
  try:
    raw = base64.b64decode(pin, validate=True)
    if base64.b64encode(raw).decode('ascii') != pin:
      raise ValueError
    root = json.loads(raw.decode('utf-8'))
  except ValueError:
    return '--release-root must be the base64 release-root payload (scripts/release_trust.py pin)'
  if (not isinstance(root, dict) or root.get('schema') != 'open-shorebird.release-root' or
      root.get('contract_version') != 2):
    return '--release-root is not a contract v2 release-root payload'
  canonical = json.dumps(root, sort_keys=True, separators=(',', ':'), ensure_ascii=False)
  if canonical.encode('utf-8') != raw:
    return '--release-root payload is not canonical JSON'
  keys = root.get('keys')
  threshold = root.get('threshold')
  if (not isinstance(keys, list) or not keys or not isinstance(threshold, int) or
      isinstance(threshold, bool) or not 1 <= threshold <= len(keys)):
    return '--release-root needs keys and a threshold between 1 and their number'
  if not development_exceptions and any(
      isinstance(key, dict) and key.get('public_key') in _DEVELOPMENT_ROOT_PUBLIC_KEYS for key in keys):
    return ('--release-root contains the DEVELOPMENT-ONLY root key; only a development build '
            '(--security-development-exceptions true) may pin it')
  return None


def _no_duplicate_keys(pairs):
  result = {}
  for key, value in pairs:
    if key in result:
      raise ValueError(f'duplicate key {key}')
    result[key] = value
  return result


def _check_diversification_profile(encoded, development_exceptions):
  """Return an error for an encoded profile that breaks contract v3 §11.2.

  The same rules as the updater's build.rs and
  scripts/diversification_profile.py: canonical base64 of canonical JSON
  (sorted keys, no whitespace, no duplicate keys), the exact v3 field set
  and constants, wire_opcodes a permutation of 0..N-1 with 2 <= N <= 256,
  Trap on wire byte 0, fewer than 16 fixed points besides Trap, and no
  DEVELOPMENT-ONLY profile without development exceptions.
  """
  if len(encoded) > _MAX_ENCODED_PROFILE:
    return f'--diversification-profile exceeds {_MAX_ENCODED_PROFILE} characters'
  try:
    raw = base64.b64decode(encoded, validate=True)
    if base64.b64encode(raw).decode('ascii') != encoded:
      raise ValueError('non-canonical base64')
    profile = json.loads(raw.decode('utf-8'), object_pairs_hook=_no_duplicate_keys)
  except ValueError:
    return ('--diversification-profile must be the base64 canonical profile JSON '
            '(scripts/diversification_profile.py gn-args)')
  if json.dumps(profile, sort_keys=True, separators=(',', ':')).encode('utf-8') != raw:
    return '--diversification-profile is not canonical JSON'
  bytecode = profile.get('bytecode') if isinstance(profile, dict) else None
  if (not isinstance(profile, dict) or
      set(profile) != {'schema', 'contract_version', 'bytecode', 'native_layout'} or
      profile['schema'] != 'open-shorebird.diversification-profile' or
      profile['contract_version'] != 3 or isinstance(profile['contract_version'], bool) or
      profile['native_layout'] is not None or not isinstance(bytecode, dict) or
      set(bytecode) != {'scheme', 'format_version', 'opcode_table_sha256', 'wire_opcodes'} or
      bytecode['scheme'] != 'opcode-permutation-v1' or bytecode['format_version'] != 3 or
      isinstance(bytecode['format_version'], bool) or
      not isinstance(bytecode['opcode_table_sha256'], str) or
      len(bytecode['opcode_table_sha256']) != 64 or
      any(c not in '0123456789abcdef' for c in bytecode['opcode_table_sha256'])):
    return '--diversification-profile is not a contract v3 diversification profile'
  wires = bytecode['wire_opcodes']
  if (not isinstance(wires, list) or not 2 <= len(wires) <= 256 or
      any(not isinstance(w, int) or isinstance(w, bool) for w in wires) or
      sorted(wires) != list(range(len(wires)))):
    return '--diversification-profile wire_opcodes must be a permutation of 0..N-1 (2 <= N <= 256)'
  if wires[0] != 0:
    return '--diversification-profile must keep Trap on wire byte 0'
  fixed = sum(1 for semantic, wire in enumerate(wires) if semantic and semantic == wire)
  if fixed >= _MAX_FIXED_POINTS:
    return f'--diversification-profile has {fixed} fixed points (at most {_MAX_FIXED_POINTS - 1})'
  profile_id = 'sha256:' + hashlib.sha256(raw).hexdigest()
  if not development_exceptions and profile_id in _DEVELOPMENT_DIVERSIFICATION_PROFILE_IDS:
    return ('--diversification-profile is the DEVELOPMENT-ONLY profile; only a development build '
            '(--security-development-exceptions true) may use it')
  return None


def _configure_security_env(env, args):
  """Set the updater's compiled-policy inputs from GN args only.

  Inherited values are removed first so a developer shell or CI step cannot
  change the compiled profile. The updater's build.rs validates the values
  again and fails the build on anything invalid or reserved.
  """
  for name in _SECURITY_ENV:
    env.pop(name, None)
  if args.security_profile not in ('legacy',) + _HARDENED_PROFILES:
    return (
        f'--security-profile must be legacy, hardened or hardened-diversified, not '
        f'{args.security_profile!r}'
    )
  hardened = args.security_profile in _HARDENED_PROFILES
  diversified = args.security_profile == 'hardened-diversified'
  if args.security_development_exceptions not in ('true', 'false'):
    return '--security-development-exceptions must be true or false'
  if hardened and not args.toolchain_id:
    return f'a {args.security_profile} updater requires --toolchain-id'
  if diversified:
    if not args.diversification_profile:
      return (
          'a hardened-diversified updater requires --diversification-profile '
          '(dart_bytecode_profile)'
      )
    error = _check_diversification_profile(
        args.diversification_profile, args.security_development_exceptions == 'true'
    )
    if error:
      return error
  elif args.diversification_profile:
    return '--diversification-profile requires --security-profile hardened-diversified'
  if hardened:
    if not args.release_root:
      return 'a hardened updater requires --release-root (the release-root pin)'
    error = _check_release_root(args.release_root, args.security_development_exceptions == 'true')
    if error:
      return error
    version = args.release_min_delegations_version
    if not (version.isdigit() and not version.startswith('0')):
      return '--release-min-delegations-version must be a positive integer'
  elif args.release_root or args.release_min_delegations_version not in ('', '1'):
    return '--release-root and --release-min-delegations-version require --security-profile hardened'
  env['SHOREBIRD_SECURITY_PROFILE'] = args.security_profile
  if args.toolchain_id:
    env['SHOREBIRD_TOOLCHAIN_ID'] = args.toolchain_id
  env['SHOREBIRD_SECURITY_DEVELOPMENT_EXCEPTIONS'] = args.security_development_exceptions
  if args.trust_root_key_id:
    env['SHOREBIRD_TRUST_ROOT_KEY_IDS'] = ','.join(args.trust_root_key_id)
  if hardened:
    env['SHOREBIRD_RELEASE_ROOT'] = args.release_root
    env['SHOREBIRD_RELEASE_MIN_DELEGATIONS_VERSION'] = args.release_min_delegations_version
  if diversified:
    env['SHOREBIRD_DIVERSIFICATION_PROFILE'] = args.diversification_profile
  return None


def _configure_msvc_env(env, rust_target):
  """Force the cc crate to compile transitive C deps with the static CRT.

  The engine's Windows build uses the static CRT. Transitive C/C++ deps
  such as zstd-sys must match it instead of defaulting to /MD and leaving
  imports such as __imp_clock that the engine's /MT link cannot resolve.

  On ARM64, ring selects the GNU-style clang driver even when cc initially
  chooses cl.exe or clang-cl. Pin that driver for all C/C++ dependencies,
  including zstd, and use its static-CRT flag. Passing /MT to this driver
  instead treats it as a filename. Other MSVC targets keep /MT, which cc
  appends after its default /MD so the static runtime takes precedence.
  """
  triple_env = rust_target.replace('-', '_')
  if rust_target == 'aarch64-pc-windows-msvc':
    env.setdefault(f'CC_{triple_env}', 'clang')
    env.setdefault(f'CXX_{triple_env}', 'clang++')
    crt_flag = '-fms-runtime-lib=static'
  else:
    crt_flag = '/MT'
  env[f'CFLAGS_{triple_env}'] = crt_flag
  env[f'CXXFLAGS_{triple_env}'] = crt_flag


def _configure_android_env(env, rust_target, ndk_path, api_level):
  """Set environment variables so cargo can cross-compile for Android."""
  # GN passes paths relative to the build output dir. Resolve to absolute
  # so that cargo and the cc crate can find the NDK tools.
  ndk_path = os.path.abspath(ndk_path)

  # Determine the host platform tag for NDK toolchain paths.
  if sys.platform.startswith('linux'):
    host_tag = 'linux-x86_64'
  elif sys.platform == 'darwin':
    host_tag = 'darwin-x86_64'
  elif sys.platform == 'win32':
    host_tag = 'windows-x86_64'
  else:
    raise RuntimeError(f'Unsupported host platform: {sys.platform}')

  toolchain_bin = os.path.join(ndk_path, 'toolchains', 'llvm', 'prebuilt', host_tag, 'bin')

  # The NDK clang binary uses a slightly different prefix for armv7.
  # Rust target: armv7-linux-androideabi
  # NDK prefix:  armv7a-linux-androideabi
  clang_prefix = rust_target
  if rust_target.startswith('armv7-'):
    clang_prefix = 'armv7a-' + rust_target[len('armv7-'):]

  clang = os.path.join(toolchain_bin, f'{clang_prefix}{api_level}-clang')
  ar = os.path.join(toolchain_bin, 'llvm-ar')

  # Cargo looks for CARGO_TARGET_<TRIPLE>_LINKER where the triple is
  # upper-cased with hyphens replaced by underscores.
  triple_env = rust_target.upper().replace('-', '_')
  env[f'CARGO_TARGET_{triple_env}_LINKER'] = clang
  env['CC'] = clang
  env['AR'] = ar


if __name__ == '__main__':
  sys.exit(main())
