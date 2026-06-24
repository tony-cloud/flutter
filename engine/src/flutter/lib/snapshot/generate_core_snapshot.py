#!/usr/bin/env python3
#
# Copyright 2026 The Flutter Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

"""Generate Flutter's core snapshot across Dart gen_snapshot flag variants."""

import argparse
import os
import subprocess
import sys


def _touch_empty(path):
  os.makedirs(os.path.dirname(path), exist_ok=True)
  with open(path, "wb"):
    pass


def _executable_path(path):
  if os.path.isabs(path) or os.sep in path:
    return path
  return "." + os.sep + path


def _supports_legacy_core_flags(gen_snapshot):
  help_output = subprocess.check_output(
      [gen_snapshot, "--help"], stderr=subprocess.STDOUT
  ).decode("utf-8", errors="replace")
  return "--vm_snapshot_data" in help_output


def main():
  parser = argparse.ArgumentParser()
  parser.add_argument("--gen-snapshot", required=True)
  parser.add_argument("--platform-kernel", required=True)
  parser.add_argument("--vm-snapshot-data", required=True)
  parser.add_argument("--vm-snapshot-instructions", required=True)
  parser.add_argument("--isolate-snapshot-data", required=True)
  parser.add_argument("--isolate-snapshot-instructions", required=True)
  parser.add_argument("--enable-asserts", action="store_true")
  args = parser.parse_args()
  gen_snapshot = _executable_path(args.gen_snapshot)

  command = [
      gen_snapshot,
      "--snapshot_kind=core",
      "--enable_mirrors=false",
  ]

  supports_legacy_core_flags = _supports_legacy_core_flags(gen_snapshot)
  if supports_legacy_core_flags:
    command.extend([
        "--vm_snapshot_data=" + args.vm_snapshot_data,
        "--vm_snapshot_instructions=" + args.vm_snapshot_instructions,
        "--isolate_snapshot_data=" + args.isolate_snapshot_data,
        "--isolate_snapshot_instructions=" + args.isolate_snapshot_instructions,
    ])
  else:
    command.extend([
        "--snapshot_data=" + args.isolate_snapshot_data,
        "--snapshot_text=" + args.isolate_snapshot_instructions,
    ])

  if args.enable_asserts:
    command.append("--enable_asserts")

  command.append(args.platform_kernel)
  subprocess.check_call(command)

  if not supports_legacy_core_flags:
    _touch_empty(args.vm_snapshot_data)
    _touch_empty(args.vm_snapshot_instructions)

  return 0


if __name__ == "__main__":
  sys.exit(main())
