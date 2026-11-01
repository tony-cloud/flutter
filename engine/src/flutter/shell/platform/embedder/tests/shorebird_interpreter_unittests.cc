// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/embedder/shorebird_aot_data.h"

#include <functional>
#include <vector>

#include "flutter/shell/common/shorebird/shorebird.h"
#include "gtest/gtest.h"

namespace flutter::testing {

TEST(ShorebirdInterpreterEmbedderTest, MissingPrivateConfigurationIsRejected) {
  FLUTTER_API_SYMBOL(FlutterEngine) engine = nullptr;
  EXPECT_EQ(
      shorebird::InitializeWithShorebirdInterpreter(
          FLUTTER_ENGINE_VERSION, nullptr, nullptr, nullptr, &engine, nullptr),
      kInvalidArguments);
  EXPECT_EQ(engine, nullptr);
}

TEST(ShorebirdInterpreterEmbedderTest, ExternalSnapshotOverridesAreRejected) {
  const ShorebirdConfigArgs args(
      "/cache", "/storage", "/signed/Host.framework/Host",
      "aot_patch_full_replacement: true\n", {"1", "2"});
  const std::vector<std::function<void(Settings&)>> overrides = {
      [](Settings& settings) {
        settings.vm_snapshot_data_path = "/external/data";
      },
      [](Settings& settings) {
        settings.vm_snapshot_instr_path = "/external/text";
      },
      [](Settings& settings) {
        settings.isolate_snapshot_data_path = "/external/data";
      },
      [](Settings& settings) {
        settings.isolate_snapshot_instr_path = "/external/text";
      },
      [](Settings& settings) {
        settings.application_library_paths = {"/external/code"};
      },
      [](Settings& settings) {
        settings.vm_snapshot_data = [] { return nullptr; };
      },
      [](Settings& settings) {
        settings.vm_snapshot_instr = [] { return nullptr; };
      },
      [](Settings& settings) {
        settings.isolate_snapshot_data = [] { return nullptr; };
      },
      [](Settings& settings) {
        settings.isolate_snapshot_instr = [] { return nullptr; };
      },
  };
  for (const auto& override_snapshot : overrides) {
    Settings settings;
    settings.assets_path = "/signed/flutter_assets";
    override_snapshot(settings);
    EXPECT_FALSE(shorebird::ConfigureSignedInterpreterHost(args, settings));
    EXPECT_EQ(settings.shorebird_interpreter_patch, nullptr);
    EXPECT_EQ(settings.shorebird_interpreter_replacement_base, nullptr);
  }
}

}  // namespace flutter::testing
