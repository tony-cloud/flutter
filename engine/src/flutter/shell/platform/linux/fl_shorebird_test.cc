// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/shell/platform/linux/fl_shorebird.h"

#include <fstream>

#include "flutter/fml/file.h"
#include "flutter/fml/paths.h"
#include "flutter/shell/common/shorebird/shorebird.h"
#include "flutter/shell/common/shorebird/updater.h"
#include "gtest/gtest.h"

namespace flutter::testing {
namespace {
class RecordingNativeUpdater : public shorebird::MockUpdater {
 public:
  shorebird::AppConfig last_config;
  bool DoInit(const shorebird::AppConfig& config) override {
    last_config = config;
    return MockUpdater::DoInit(config);
  }
};
class ShorebirdLinuxBoundaryTest : public ::testing::Test {
 protected:
  void SetUp() override {
    shorebird::Updater::ResetLaunchStateForTesting();
    auto updater = std::make_unique<RecordingNativeUpdater>();
    updater_ = updater.get();
    shorebird::Updater::SetInstanceForTesting(std::move(updater));
  }
  void TearDown() override {
    shorebird::Updater::ResetInstanceForTesting();
    shorebird::Updater::ResetLaunchStateForTesting();
  }
  void Write(const char* name, const std::string& bytes) {
    std::ofstream file(fml::paths::JoinPaths({assets_.path(), name}),
                       std::ios::binary);
    file << bytes;
  }
  fml::ScopedTemporaryDirectory assets_;
  RecordingNativeUpdater* updater_ = nullptr;
};
TEST_F(ShorebirdLinuxBoundaryTest,
       V2ScopeAndOriginalCustomProjectPathReachInitialization) {
  Write("shorebird.yaml", "app_id: app\nselection_protocol: 2\n");
  Write("version.json", R"({"version":"1.0","build_number":"7"})");
  const auto scope_name = ReleaseScopeAssetName("linux", ShorebirdHostArch());
  const auto scope =
      R"({"app_id":"app","release_version":"1.0+7","platform":"linux","arch":")" +
      ShorebirdHostArch() + R"(","base_artifact_hash":")" +
      std::string(64, 'a') +
      R"(","host_abi_hash":null,"runtime_profile":"native-aot"})";
  Write(scope_name.c_str(), scope);
  std::string patch;
  ASSERT_TRUE(SetUpShorebird(assets_.path().c_str(),
                             "/custom/original/release.so", patch));
  EXPECT_EQ(updater_->last_config.original_libapp_paths,
            std::vector<std::string>{"/custom/original/release.so"});
  EXPECT_EQ(updater_->last_config.release_scope_json, scope);
  EXPECT_TRUE(updater_->last_config.selection_protocol_v2);
  EXPECT_EQ(updater_->last_config.release_baseline_callbacks.open, nullptr);
  EXPECT_EQ(updater_->validate_count(), 0);
  EXPECT_TRUE(patch.empty());
}
TEST_F(ShorebirdLinuxBoundaryTest,
       V2VersionFailureCannotFallBackToLegacyInitialization) {
  Write("shorebird.yaml", "app_id: app\nselection_protocol: 2\n");
  Write("version.json", R"({"version":false})");
  std::string patch;
  EXPECT_FALSE(
      SetUpShorebird(assets_.path().c_str(), "/custom/release.so", patch));
  EXPECT_TRUE(updater_->RequiresSelectionV2());
  EXPECT_TRUE(updater_->UsesPreparedBootSource());
  EXPECT_EQ(updater_->init_count(), 0);
  EXPECT_FALSE(updater_->Init(shorebird::AppConfig{}));
}
}  // namespace
}  // namespace flutter::testing
