#include "flutter/shell/common/shorebird/shorebird.h"

#include <algorithm>
#include <memory>
#include <string>
#include <vector>

#include "flutter/runtime/shorebird/interpreter_patch.h"
#include "flutter/shell/common/shorebird/updater.h"
#include "gtest/gtest.h"

namespace flutter {
namespace testing {
class LoadPatchOrBaseTest : public ::testing::Test {
 protected:
  void SetUp() override {
    auto mock = std::make_unique<shorebird::MockUpdater>();
    mock_ = mock.get();
    shorebird::Updater::SetInstanceForTesting(std::move(mock));
    shorebird::Updater::ResetLaunchStateForTesting();
  }

  void TearDown() override {
    mock_ = nullptr;
    shorebird::Updater::ResetInstanceForTesting();
    shorebird::Updater::ResetLaunchStateForTesting();
  }

  // Loads only the paths in |loadable|, recording every attempt.
  bool Load(const std::string& path) {
    attempts_.push_back(path);
    return std::find(loadable_.begin(), loadable_.end(), path) !=
           loadable_.end();
  }

  bool Run(const std::string& patch_path) {
    return LoadPatchOrBase(
        patch_path, "base.so",
        [this](const std::string& path) { return Load(path); });
  }

  shorebird::MockUpdater* mock_ = nullptr;
  std::vector<std::string> loadable_;
  std::vector<std::string> attempts_;
};

TEST_F(LoadPatchOrBaseTest, LoadsBaseWithoutAPatch) {
  loadable_ = {"base.so"};

  EXPECT_TRUE(Run(""));
  EXPECT_EQ(attempts_, std::vector<std::string>({"base.so"}));
  EXPECT_TRUE(mock_->call_log().empty());
}

TEST_F(LoadPatchOrBaseTest, LoadsPatchWithoutReporting) {
  loadable_ = {"patch.vmcode", "base.so"};

  EXPECT_TRUE(Run("patch.vmcode"));
  EXPECT_EQ(attempts_, std::vector<std::string>({"patch.vmcode"}));
  // The Shell reports the boot once it exists.
  EXPECT_TRUE(mock_->call_log().empty());
}

TEST_F(LoadPatchOrBaseTest, ReportsAFailedPatchAndLoadsBase) {
  loadable_ = {"base.so"};

  EXPECT_TRUE(Run("patch.vmcode"));
  EXPECT_EQ(attempts_, std::vector<std::string>({"patch.vmcode", "base.so"}));
  const auto& log = mock_->call_log();
  ASSERT_EQ(log.size(), 2u);
  EXPECT_EQ(log[0], "ReportLaunchStart");
  EXPECT_EQ(log[1], "ReportLaunchFailure");
}

// The Shell that boots the base code reports start and success. Neither may
// reach the updater, or it would record the failed patch as booted.
TEST_F(LoadPatchOrBaseTest, BaseBootAfterAFailedPatchIsNotReportedAsSuccess) {
  loadable_ = {"base.so"};
  ASSERT_TRUE(Run("patch.vmcode"));

  shorebird::Updater::Instance().ReportLaunchStart();
  shorebird::Updater::Instance().ReportLaunchSuccess();

  EXPECT_EQ(mock_->launch_start_count(), 1);
  EXPECT_EQ(mock_->launch_failure_count(), 1);
  EXPECT_EQ(mock_->launch_success_count(), 0);
}

TEST_F(LoadPatchOrBaseTest, FailsWhenNeitherLoads) {
  EXPECT_FALSE(Run("patch.vmcode"));
  EXPECT_EQ(attempts_, std::vector<std::string>({"patch.vmcode", "base.so"}));
  EXPECT_EQ(mock_->launch_failure_count(), 1);
}

namespace {
class RecordingUpdater : public shorebird::MockUpdater {
 public:
  shorebird::AppConfig last_config;
  bool DoInit(const shorebird::AppConfig& config) override {
    last_config = config;
    return MockUpdater::DoInit(config);
  }
};

std::string SignedFullProfile() {
  return "app_id: app\n"
         "aot_patch_full_replacement: true\n"
         "aot_patch_runtime_mode: dart-bytecode-interpreter\n"
         "aot_patch_replacement_base: shorebird_replacement_base.sbr\n"
         "aot_patch_host_abi: " +
         std::string(64, 'a') +
         "\n"
         "aot_patch_base_snapshot_hash: " +
         std::string(64, 'b') + "\n";
}

class DesktopInterpreterConfigTest : public ::testing::Test {
 protected:
  void SetUp() override {
    shorebird::ResetInterpreterKeyProviderForTesting();
    auto updater = std::make_unique<RecordingUpdater>();
    updater_ = updater.get();
    shorebird::Updater::SetInstanceForTesting(std::move(updater));
    settings_.assets_path = "/signed/custom/flutter_assets";
  }
  void TearDown() override {
    shorebird::Updater::ResetInstanceForTesting();
    shorebird::ResetInterpreterKeyProviderForTesting();
  }
  ShorebirdConfigArgs Args() {
    return {"/root/cache",
            "/root/storage",
            "/signed/Custom.framework/Custom",
            SignedFullProfile(),
            {"1.0", "2"}};
  }
  RecordingUpdater* updater_;
  Settings settings_;
};
}  // namespace

TEST_F(DesktopInterpreterConfigTest, PreservesDesktopScopeAndWholeFramework) {
  updater_->set_next_boot_patch_path("/cache/update.aotpatch");
  const auto args = Args();
  ASSERT_TRUE(ConfigureShorebirdInterpreter(args, settings_));
  EXPECT_EQ(updater_->last_config.code_cache_dir,
            "/root/cache/shorebird_updater/app");
  EXPECT_EQ(updater_->last_config.app_storage_dir,
            "/root/storage/shorebird_updater/app");
  EXPECT_EQ(updater_->last_config.original_libapp_paths,
            std::vector<std::string>{"/signed/Custom.framework/Custom"});
  EXPECT_EQ(updater_->last_config.release_version, "1.0+2");
  ASSERT_NE(settings_.shorebird_interpreter_patch, nullptr);
  EXPECT_EQ(settings_.shorebird_interpreter_patch->target,
            shorebird::InterpreterPatchTarget::kMacOSArm64);
  EXPECT_TRUE(settings_.shorebird_interpreter_patch->full_replacement);
  EXPECT_EQ(settings_.shorebird_interpreter_patch->app_build_id, "1.0+2");
  EXPECT_EQ(settings_.shorebird_interpreter_replacement_base->path,
            "/signed/custom/flutter_assets/shorebird_replacement_base.sbr");
  // Initialization never reports a boot or loads an executable patch image.
  EXPECT_EQ(updater_->launch_start_count(), 0);
}

TEST_F(DesktopInterpreterConfigTest,
       UpdaterFailureRetainsSignedBaseWithoutKey) {
  updater_->set_init_result(false);
  updater_->set_next_boot_patch_path("/cache/stale.aotpatch");
  ASSERT_TRUE(ConfigureShorebirdInterpreter(Args(), settings_));
  EXPECT_EQ(settings_.shorebird_interpreter_patch, nullptr);
  ASSERT_NE(settings_.shorebird_interpreter_replacement_base, nullptr);
  EXPECT_TRUE(settings_.shorebird_interpreter_replacement_base->validation_error
                  .empty());
  EXPECT_FALSE(shorebird::RegisterInterpreterKeyProvider(
      [](const char*, uint8_t*, intptr_t, intptr_t*) { return false; }));
}

TEST_F(DesktopInterpreterConfigTest, InvalidBaseRetainedAndStartupRejected) {
  auto args = Args();
  args.shorebird_yaml += "aot_patch_structural_updates: true\n";
  EXPECT_FALSE(ConfigureShorebirdInterpreter(args, settings_));
  ASSERT_NE(settings_.shorebird_interpreter_replacement_base, nullptr);
  EXPECT_FALSE(settings_.shorebird_interpreter_replacement_base
                   ->validation_error.empty());
  EXPECT_EQ(updater_->init_count(), 0);
}

TEST_F(DesktopInterpreterConfigTest, SettingsOwnSelectionAfterArgumentsGoAway) {
  {
    auto args = Args();
    updater_->set_next_boot_patch_path("/cache/first.aotpatch");
    ASSERT_TRUE(ConfigureShorebirdInterpreter(args, settings_));
  }
  Settings retained(settings_);
  settings_ = Settings();
  EXPECT_EQ(retained.shorebird_interpreter_patch->path,
            "/cache/first.aotpatch");
  EXPECT_EQ(retained.shorebird_interpreter_replacement_base->host_abi,
            std::string(64, 'a'));
  updater_->set_next_boot_patch_path("/cache/background.aotpatch");
  settings_.assets_path = retained.assets_path;
  ASSERT_TRUE(ConfigureShorebirdInterpreter(Args(), settings_));
  EXPECT_EQ(settings_.shorebird_interpreter_patch,
            retained.shorebird_interpreter_patch);
}

TEST_F(DesktopInterpreterConfigTest, BaseOnlyChoiceIsSealedAcrossLaterEngines) {
  ASSERT_TRUE(ConfigureShorebirdInterpreter(Args(), settings_));
  updater_->set_next_boot_patch_path("/cache/background.aotpatch");
  ASSERT_TRUE(ConfigureShorebirdInterpreter(Args(), settings_));
  EXPECT_EQ(settings_.shorebird_interpreter_patch, nullptr);
}

}  // namespace testing
}  // namespace flutter