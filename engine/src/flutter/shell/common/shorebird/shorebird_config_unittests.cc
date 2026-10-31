// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/shell/common/shorebird/shorebird.h"

#include <utility>
#include <vector>

#include "flutter/runtime/shorebird/interpreter_patch.h"
#include "gtest/gtest.h"

namespace flutter::testing {

TEST(Shorebird, GetValueFromYamlValueExists) {
  std::string yaml = "appid: com.example.app\nversion: 1.0.0\n";
  std::string key = "appid";
  std::string value = GetValueFromYaml(yaml, key);
  EXPECT_EQ(value, "com.example.app");
}

TEST(Shorebird, GetValueFromYamlValueDoesNotExist) {
  std::string yaml = "appid: com.example.app\nversion: 1.0.0\n";
  std::string key = "appid2";
  std::string value = GetValueFromYaml(yaml, key);
  EXPECT_EQ(value, "");
}

TEST(Shorebird, CompiledYamlScalarsUseExactKeysAndUnquoteStrings) {
  EXPECT_EQ(GetValueFromYaml("other_app_id: wrong\napp_id: '123'\n", "app_id"),
            "123");
  EXPECT_EQ(GetValueFromYaml("# app_id: wrong\napp_id: \"app\"\n", "app_id"),
            "app");
  EXPECT_EQ(GetValueFromYaml("app_id: 'customer''s'\n", "app_id"),
            "customer's");
}

std::string FullReplacementYaml() {
  return "aot_patch_full_replacement: true\n"
         "aot_patch_runtime_mode: dart-bytecode-interpreter\n"
         "aot_patch_replacement_base: shorebird_replacement_base.sbr\n"
         "aot_patch_host_abi: " +
         std::string(64, 'a') +
         "\n"
         "aot_patch_base_snapshot_hash: " +
         std::string(64, 'b') + "\n";
}

TEST(Shorebird, FullReplacementBaseUsesSignedAssetsWithoutAesOrUpdaterConfig) {
  const auto base = LoadInterpreterReplacementBaseConfig(
      FullReplacementYaml(), "/signed/flutter_assets");
  ASSERT_NE(base, nullptr);
  EXPECT_TRUE(base->validation_error.empty());
  EXPECT_EQ(base->path,
            "/signed/flutter_assets/shorebird_replacement_base.sbr");
  EXPECT_EQ(base->host_abi, std::string(64, 'a'));
  EXPECT_EQ(base->snapshot_hash, std::string(64, 'b'));
}

TEST(Shorebird, LegacyProfilesDoNotRequireReplacementBase) {
  EXPECT_EQ(LoadInterpreterReplacementBaseConfig("", ""), nullptr);
  EXPECT_EQ(LoadInterpreterReplacementBaseConfig(
                "aot_patch_full_replacement: false\n", ""),
            nullptr);
}

TEST(Shorebird, InvalidFullProfileIsRetainedToFailClosed) {
  const auto yaml = FullReplacementYaml();
  auto expect_invalid = [](const std::string& source,
                           const std::string& assets =
                               "/signed/flutter_assets") {
    const auto base = LoadInterpreterReplacementBaseConfig(source, assets);
    ASSERT_NE(base, nullptr);
    EXPECT_FALSE(base->validation_error.empty());
    EXPECT_TRUE(base->path.empty());
  };
  expect_invalid(yaml, "");
  expect_invalid(yaml + "aot_patch_structural_updates: true\n");
  expect_invalid(yaml + "aot_patch_structural_updates: yes\n");
  expect_invalid(yaml + "aot_patch_full_replacement: false\n");
  expect_invalid(yaml + "aot_patch_host_abi: " + std::string(64, 'a') + "\n");
  expect_invalid("aot_patch_full_replacement:\n");
  for (const auto& replacement :
       std::vector<std::pair<std::string, std::string>>{
           {"true", "yes"},
           {"dart-bytecode-interpreter", "native-aot"},
           {"shorebird_replacement_base.sbr",
            "../shorebird_replacement_base.sbr"},
           {"shorebird_replacement_base.sbr", "/updater/base.sbr"},
           {std::string(64, 'a'), std::string(64, 'A')},
           {std::string(64, 'b'), "123"}}) {
    auto malformed = yaml;
    malformed.replace(malformed.find(replacement.first),
                      replacement.first.size(), replacement.second);
    expect_invalid(malformed);
  }
}

}  // namespace flutter::testing
