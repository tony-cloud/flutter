// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/shell/common/shorebird/shorebird.h"

#include <fstream>
#include <utility>
#include <vector>

#include "flutter/fml/file.h"
#include "flutter/fml/paths.h"
#include "flutter/runtime/shorebird/interpreter_patch.h"
#include "flutter/shell/common/shorebird/updater.h"
#include "gtest/gtest.h"

namespace flutter::testing {

TEST(Shorebird, V2ScopeNeverDowngradesWhenMissingOrAmbiguous) {
  for (const auto& yaml : {"selection_protocol: 2\n", "selection_protocol: 9\n",
                           "selection_protocol: 1\nselection_protocol: 2\n"}) {
    shorebird::Updater::ResetLaunchStateForTesting();
    shorebird::AppConfig config;
    config.yaml_config = yaml;
    EXPECT_FALSE(
        ConfigureSelectionV2(config, "/missing/assets", "macos", "aarch64"));
    EXPECT_TRUE(config.selection_protocol_v2);
    EXPECT_TRUE(shorebird::Updater::Instance().UsesPreparedBootSource());
    // A different engine's legacy initializer cannot recover by downgrading.
    shorebird::MockUpdater mock;
    EXPECT_FALSE(mock.Init(shorebird::AppConfig{}));
    EXPECT_EQ(mock.init_count(), 0);
  }
  shorebird::Updater::ResetLaunchStateForTesting();
}
TEST(Shorebird, V2OriginalBytecodeStreamIsIndependentOwnedAndFreshOnEveryOpen) {
  ResetSelectionV2BaselineForTesting();
  shorebird::Updater::ResetLaunchStateForTesting();
  fml::ScopedTemporaryDirectory assets;
  auto write = [&](const char* name, const std::string& data) {
    std::ofstream stream(fml::paths::JoinPaths({assets.path(), name}),
                         std::ios::binary);
    stream << data;
  };
  const std::string hash(64, 'a');
  const auto scope =
      R"({"app_id":"app","release_version":"1.0+1","platform":"ios","arch":"aarch64","base_artifact_hash":")" +
      hash +
      R"(","host_abi_hash":null,"runtime_profile":"interpreter-structural"})";
  const char* scope_name = "shorebird_release_scope_ios_aarch64.json";
  write(scope_name, scope);
  write(shorebird::kInterpreterBaseAsset, "original-released-bytecode");
  shorebird::AppConfig config;
  config.release_version = "1.0+1";
  config.yaml_config =
      "selection_protocol: 2\napp_id: app\n"
      "aot_patch_runtime_mode: dart-bytecode-interpreter\n"
      "aot_patch_structural_updates: true\naot_patch_base_snapshot_hash: " +
      hash + "\n";
  ASSERT_TRUE(ConfigureSelectionV2(config, assets.path(), "ios", "aarch64"));
  EXPECT_EQ(config.release_scope_json, scope);
  EXPECT_EQ(config.file_callbacks.open, nullptr);
  const auto& callbacks = config.release_baseline_callbacks;
  ASSERT_NE(callbacks.open, nullptr);
  // Changes to the asset path after configuration cannot alter these streams.
  write(shorebird::kInterpreterBaseAsset, "another-file-at-the-same-path");
  void* first = callbacks.open();
  void* second = callbacks.open();
  ASSERT_NE(first, nullptr);
  ASSERT_NE(second, nullptr);
  uint8_t bytes[64] = {};
  EXPECT_EQ(callbacks.read(first, bytes, 8), 8u);
  const auto count = callbacks.read(second, bytes, sizeof(bytes));
  EXPECT_EQ(std::string(reinterpret_cast<char*>(bytes), count),
            "original-released-bytecode");
  EXPECT_EQ(callbacks.seek(first, 0, SEEK_SET), 0);
  EXPECT_EQ(callbacks.read(first, bytes, 8), 8u);
  EXPECT_EQ(std::string(reinterpret_cast<char*>(bytes), 8), "original");
  EXPECT_EQ(callbacks.seek(first, -100, SEEK_CUR), -1);
  callbacks.close(first);
  callbacks.close(second);
  // Duplicate/extra scope members and a different host architecture fail.
  write(scope_name, scope.substr(0, scope.size() - 1) + ",\"unknown\":null}");
  EXPECT_FALSE(ConfigureSelectionV2(config, assets.path(), "ios", "aarch64"));
  write(scope_name, scope);
  EXPECT_FALSE(ConfigureSelectionV2(config, assets.path(), "ios", "x86_64"));
  ResetSelectionV2BaselineForTesting();
  shorebird::Updater::ResetLaunchStateForTesting();
}

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

TEST(Shorebird, NativePatchBudgetUsesReleaseDefaultOrExplicitOverride) {
  uint64_t budget = 0;
  ASSERT_TRUE(ResolveNativePatchMaxBytes("", 0, budget));
  EXPECT_EQ(budget, 512ULL * 1024 * 1024);
  ASSERT_TRUE(ResolveNativePatchMaxBytes("", 4096, budget));
  EXPECT_EQ(budget, 4096u);
  ASSERT_TRUE(
      ResolveNativePatchMaxBytes("native_patch_max_bytes: 4096\n", 0, budget));
  EXPECT_EQ(budget, 4096u);
  EXPECT_TRUE(ResolveNativePatchMaxBytes("native_patch_max_bytes: 4096\n", 4096,
                                         budget));
  EXPECT_FALSE(ResolveNativePatchMaxBytes("native_patch_max_bytes: 4096\n",
                                          8192, budget));
  EXPECT_TRUE(ResolveNativePatchMaxBytes(
      "native_patch_max_bytes: 9223372036854775807\n", 0, budget));
  EXPECT_EQ(budget, 9223372036854775807ULL);
}

TEST(Shorebird, NativePatchBudgetRejectsMalformedAmbiguousAndOverflowValues) {
  for (const auto& value : {"", "0", "-1", "+1", "1.0", "1e6", "0x1000", "null",
                            "true", "1 # comment", "9223372036854775808",
                            "18446744073709551616", "'bad'", "[1024]"}) {
    uint64_t budget = 123;
    EXPECT_FALSE(ResolveNativePatchMaxBytes(
        "native_patch_max_bytes: " + std::string(value) + "\n", 0, budget))
        << value;
    EXPECT_EQ(budget, 0u);
  }
  uint64_t budget = 0;
  EXPECT_FALSE(ResolveNativePatchMaxBytes(
      "native_patch_max_bytes: 1\nnative_patch_max_bytes: 1\n", 0, budget));
  EXPECT_FALSE(ResolveNativePatchMaxBytes("", 9223372036854775808ULL, budget));
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
            fml::paths::JoinPaths(
                {"/signed/flutter_assets", "shorebird_replacement_base.sbr"}));
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
