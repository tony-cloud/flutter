#include "flutter/shell/common/shorebird/shorebird.h"

#include <algorithm>
#include <fstream>
#include <memory>

#include <string>
#include <utility>
#include <vector>
#include "flutter/fml/file.h"
#include "flutter/fml/paths.h"

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
  int prepared_count = 0;
  int begun_count = 0;
  std::unique_ptr<shorebird::PreparedBootSource> PrepareBootSource() override {
    ++prepared_count;
    return std::make_unique<shorebird::PreparedBootSource>(
        shorebird::PreparedBootSource::Kind::kBase, 42, 0, 0, -1, "");
  }
  bool DoBeginBootSource(uint64_t id) override {
    EXPECT_EQ(id, 42u);
    ++begun_count;
    return true;
  }
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
    shorebird::Updater::ResetLaunchStateForTesting();
    ResetSelectionV2BaselineForTesting();
    auto updater = std::make_unique<RecordingUpdater>();
    updater_ = updater.get();
    shorebird::Updater::SetInstanceForTesting(std::move(updater));
    settings_.assets_path = "/signed/custom/flutter_assets";
  }
  void TearDown() override {
    shorebird::Updater::ResetInstanceForTesting();
    shorebird::ResetInterpreterKeyProviderForTesting();
    shorebird::Updater::ResetLaunchStateForTesting();
    ResetSelectionV2BaselineForTesting();
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

TEST_F(DesktopInterpreterConfigTest,
       V2MissingAppIdStillRequiresCheckedStartup) {
  auto args = Args();
  args.shorebird_yaml = "selection_protocol: 2\n";
  std::string patch;
  EXPECT_FALSE(ConfigureShorebird(args, patch));
  EXPECT_TRUE(updater_->RequiresSelectionV2());
  EXPECT_TRUE(updater_->UsesPreparedBootSource());
  EXPECT_EQ(updater_->init_count(), 0);
}

TEST_F(DesktopInterpreterConfigTest, CompiledV2MissingScopeRefusesStartup) {
  auto args = Args();
  args.shorebird_yaml += "selection_protocol: 2\n";
  EXPECT_FALSE(ConfigureShorebirdInterpreter(args, settings_));
  EXPECT_EQ(updater_->init_count(), 0);
  EXPECT_EQ(updater_->prepared_count, 0);
  EXPECT_EQ(settings_.shorebird_interpreter_patch, nullptr);
}
#if FML_OS_MACOSX && !FML_OS_IOS && (FML_ARCH_CPU_ARM64 || FML_ARCH_CPU_X86_64)
TEST_F(DesktopInterpreterConfigTest,
       V2CheckedInitFailureRefusesUnpreparedBase) {
  fml::ScopedTemporaryDirectory assets;
  settings_.assets_path = assets.path();
  auto args = Args();
  args.shorebird_yaml += "selection_protocol: 2\n";
  const auto scope =
      R"({"app_id":"app","release_version":"1.0+2","platform":"macos","arch":")" +
      ShorebirdHostArch() + R"(","base_artifact_hash":")" +
      std::string(64, 'b') + R"(","host_abi_hash":")" + std::string(64, 'a') +
      R"(","runtime_profile":"interpreter-full"})";
  {
    std::ofstream file(fml::paths::JoinPaths(
        {assets.path(), ReleaseScopeAssetName("macos", ShorebirdHostArch())}));
    file << scope;
    std::ofstream baseline(fml::paths::JoinPaths(
        {assets.path(), shorebird::kReplacementBaseAsset}));
    baseline << "original-full-baseline";
  }
  updater_->set_init_result(false);
  EXPECT_FALSE(ConfigureShorebirdInterpreter(args, settings_));
  EXPECT_EQ(updater_->init_count(), 1);
  EXPECT_EQ(updater_->prepared_count, 0);
  EXPECT_TRUE(updater_->last_config.selection_protocol_v2);
  EXPECT_NE(updater_->last_config.release_baseline_callbacks.open, nullptr);
}
TEST_F(DesktopInterpreterConfigTest, ValidV2NoGrantBeginsPreparedFreeBase) {
  fml::ScopedTemporaryDirectory assets;
  settings_.assets_path = assets.path();
  auto args = Args();
  args.shorebird_yaml += "selection_protocol: 2\n";
  {
    std::ofstream file(fml::paths::JoinPaths(
        {assets.path(), ReleaseScopeAssetName("macos", ShorebirdHostArch())}));
    file
        << R"({"app_id":"app","release_version":"1.0+2","platform":"macos","arch":")" +
               ShorebirdHostArch() + R"(","base_artifact_hash":")" +
               std::string(64, 'b') + R"(","host_abi_hash":")" +
               std::string(64, 'a') +
               R"(","runtime_profile":"interpreter-full"})";
    std::ofstream baseline(fml::paths::JoinPaths(
        {assets.path(), shorebird::kReplacementBaseAsset}));
    baseline << "original-full-baseline";
  }
  ASSERT_TRUE(ConfigureShorebirdInterpreter(args, settings_));
  EXPECT_EQ(settings_.shorebird_interpreter_patch, nullptr);
  ASSERT_TRUE(settings_.shorebird_interpreter_begin_base);
  EXPECT_EQ(updater_->begun_count, 0);
  EXPECT_TRUE(settings_.shorebird_interpreter_begin_base());
  EXPECT_EQ(updater_->begun_count, 1);
  EXPECT_EQ(updater_->validate_count(), 0);
}

TEST_F(DesktopInterpreterConfigTest,
       V2WrongScopeOsOrArchRefusesBeforeUpdaterInit) {
  fml::ScopedTemporaryDirectory assets;
  settings_.assets_path = assets.path();
  auto args = Args();
  args.shorebird_yaml += "selection_protocol: 2\n";
  const std::string other_arch =
      ShorebirdHostArch() == "x86_64" ? "aarch64" : "x86_64";
  for (const auto& target :
       {std::make_pair(std::string("macos"), other_arch),
        std::make_pair(std::string("ios"), ShorebirdHostArch())}) {
    std::ofstream file(fml::paths::JoinPaths(
        {assets.path(), ReleaseScopeAssetName("macos", ShorebirdHostArch())}));
    file << R"({"app_id":"app","release_version":"1.0+2","platform":")" +
                target.first + R"(","arch":")" + target.second +
                R"(","base_artifact_hash":")" + std::string(64, 'b') +
                R"(","host_abi_hash":")" + std::string(64, 'a') +
                R"(","runtime_profile":"interpreter-full"})";
    file.close();
    EXPECT_FALSE(ConfigureShorebirdInterpreter(args, settings_));
    EXPECT_EQ(updater_->init_count(), 0);
    EXPECT_EQ(updater_->prepared_count, 0);
    EXPECT_TRUE(updater_->RequiresSelectionV2());
    EXPECT_EQ(settings_.shorebird_interpreter_patch, nullptr);
  }
}
TEST_F(DesktopInterpreterConfigTest,
       MacBodyAndStructuralProfilesRefuseStartup) {
  auto args = Args();
  for (const auto* structural : {"false", "true"}) {
    args.shorebird_yaml =
        "selection_protocol: 2\napp_id: app\n"
        "aot_patch_runtime_mode: dart-bytecode-interpreter\n"
        "aot_patch_full_replacement: false\naot_patch_structural_updates: " +
        std::string(structural) + "\n";
    EXPECT_FALSE(ConfigureShorebirdInterpreter(args, settings_));
    EXPECT_EQ(updater_->init_count(), 0);
    EXPECT_EQ(updater_->prepared_count, 0);
    EXPECT_EQ(settings_.shorebird_interpreter_patch, nullptr);
  }
}

#endif

TEST_F(DesktopInterpreterConfigTest, PreservesDesktopScopeAndWholeFramework) {
  updater_->set_next_boot_patch_path("/cache/update.aotpatch");
  const auto args = Args();
  ASSERT_TRUE(ConfigureShorebirdInterpreter(args, settings_));
  EXPECT_EQ(updater_->last_config.code_cache_dir,
            fml::paths::JoinPaths(
                {args.code_cache_path, "shorebird_updater", "app"}));
  EXPECT_EQ(updater_->last_config.app_storage_dir,
            fml::paths::JoinPaths(
                {args.app_storage_path, "shorebird_updater", "app"}));
  EXPECT_EQ(updater_->last_config.original_libapp_paths,
            std::vector<std::string>{"/signed/Custom.framework/Custom"});
  EXPECT_EQ(updater_->last_config.release_version, "1.0+2");
  ASSERT_NE(settings_.shorebird_interpreter_patch, nullptr);
  EXPECT_EQ(settings_.shorebird_interpreter_patch->target,
            ShorebirdHostArch() == "x86_64"
                ? shorebird::InterpreterPatchTarget::kMacOSX64
                : shorebird::InterpreterPatchTarget::kMacOSArm64);
  EXPECT_TRUE(settings_.shorebird_interpreter_patch->full_replacement);
  EXPECT_EQ(settings_.shorebird_interpreter_patch->app_build_id, "1.0+2");
  EXPECT_EQ(settings_.shorebird_interpreter_replacement_base->path,
            fml::paths::JoinPaths(
                {settings_.assets_path, "shorebird_replacement_base.sbr"}));
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