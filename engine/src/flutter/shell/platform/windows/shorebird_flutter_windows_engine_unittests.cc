// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/windows/flutter_windows_engine.h"

#include <deque>
#include <memory>
#include <utility>
#include <vector>

#include "flutter/fml/file.h"
#include "flutter/fml/mapping.h"
#include "flutter/fml/paths.h"
#include "flutter/fml/platform/win/wstring_conversion.h"
#include "flutter/fml/synchronization/waitable_event.h"
#include "flutter/shell/common/shorebird/updater.h"
#include "flutter/shell/platform/embedder/test_utils/proc_table_replacement.h"
#include "flutter/shell/platform/windows/testing/engine_modifier.h"
#include "flutter/shell/platform/windows/testing/windows_test.h"
#include "gtest/gtest.h"

namespace flutter::testing {
namespace {

using shorebird::PreparedBootSource;
using Kind = PreparedBootSource::Kind;

constexpr uint64_t kMemorySelection = 896542;
constexpr uint64_t kBaseSelection = 896543;

class PreparedMemoryUpdater : public shorebird::MockUpdater {
 public:
  std::unique_ptr<PreparedBootSource> PrepareBootSource() override {
    prepare_count++;
    if (sources.empty()) {
      return nullptr;
    }
    auto source = std::move(sources.front());
    sources.pop_front();
    return source;
  }

  bool DoBeginBootSource(uint64_t selection_id) override {
    begun.push_back(selection_id);
    return true;
  }

  bool DoAbortBootSource(uint64_t selection_id) override {
    aborted.push_back(selection_id);
    return true;
  }

  std::deque<std::unique_ptr<PreparedBootSource>> sources;
  std::vector<uint64_t> begun;
  std::vector<uint64_t> aborted;
  int prepare_count = 0;
};

}  // namespace

class ShorebirdFlutterWindowsEngineTest : public WindowsTest {
 public:
  void SetUp() override {
    WindowsTest::SetUp();
    if (!FlutterEngineRunsAOTCompiledDartCode()) {
      GTEST_SKIP() << "Requires the Windows release AOT fixture.";
    }
    shorebird::Updater::ResetLaunchStateForTesting();
    auto updater = std::make_unique<PreparedMemoryUpdater>();
    updater_ = updater.get();
    shorebird::Updater::SetInstanceForTesting(std::move(updater));
    shorebird::AppConfig config = {};
    config.max_native_image_bytes = 64 * 1024 * 1024;
    ASSERT_TRUE(updater_->Init(config));

    // Missing app configuration leaves the injected prepared selection alone.
    // The generated fixture directory contains only the compiled Dart assets.
    ASSERT_FALSE(fml::IsFile(
        fml::paths::JoinPaths({GetFixturesDirectory(), "shorebird.yaml"})));
    auto signal = CREATE_NATIVE_ENTRY(
        [this](Dart_NativeArguments args) { dart_entered_.Signal(); });
    GetContext().AddNativeFunction("Signal", signal);
  }

  void TearDown() override {
    shorebird::Updater::ResetInstanceForTesting();
    shorebird::Updater::ResetLaunchStateForTesting();
    WindowsTest::TearDown();
  }

 protected:
  std::string AotPath() const {
    return fml::paths::JoinPaths(
        {GetFixturesDirectory(), "app_elf_snapshot.so"});
  }

  std::unique_ptr<FlutterWindowsEngine> BuildEngine() {
    const auto aot_path = fml::Utf8ToWideString(AotPath());
    FlutterDesktopEngineProperties properties = {};
    properties.assets_path = GetContext().GetAssetsPath().c_str();
    properties.icu_data_path = GetContext().GetIcuDataPath().c_str();
    properties.aot_library_path = aot_path.c_str();
    properties.dart_entrypoint = "verifyNativeFunction";
    properties.impeller_switch = DisabledImpeller;
    properties.ui_thread_policy =
        FlutterDesktopUIThreadPolicy::RunOnSeparateThread;
    auto engine = std::make_unique<FlutterWindowsEngine>(
        FlutterProjectBundle(properties));
    engine->SetRootIsolateCreateCallback(GetContext().GetRootIsolateCallback());
    EngineModifier modifier(engine.get());
    modifier.SetEGLManager(nullptr);
    const auto create_aot = modifier.embedder_api().CreateAOTData;
    modifier.embedder_api().CreateAOTData = MOCK_ENGINE_PROC(
        CreateAOTData,
        ([this, create_aot](const FlutterEngineAOTDataSource* source,
                            FlutterEngineAOTData* data) {
          path_loads_.push_back(source->elf_path);
          begin_at_path_load_.push_back(updater_->begun);
          return create_aot(source, data);
        }));
    return engine;
  }

  std::weak_ptr<const uint8_t> QueueMemory(std::vector<uint8_t> bytes,
                                           uint64_t selection_id) {
    auto storage = std::make_shared<std::vector<uint8_t>>(std::move(bytes));
    std::shared_ptr<const uint8_t> lease(storage, storage->data());
    std::weak_ptr<const uint8_t> weak_lease = lease;
    updater_->sources.push_back(std::make_unique<PreparedBootSource>(
        Kind::kMemory, selection_id, 17, storage->size(), -1, "",
        std::move(lease)));
    return weak_lease;
  }

  void QueueBase() {
    updater_->sources.push_back(std::make_unique<PreparedBootSource>(
        Kind::kBase, kBaseSelection, 0, 0, -1, ""));
  }

  void ExpectDartEntered() {
    EXPECT_FALSE(
        dart_entered_.WaitWithTimeout(fml::TimeDelta::FromSeconds(10)));
  }

  PreparedMemoryUpdater* updater_ = nullptr;
  fml::AutoResetWaitableEvent dart_entered_;
  std::vector<std::string> path_loads_;
  std::vector<std::vector<uint64_t>> begin_at_path_load_;
};

TEST_F(ShorebirdFlutterWindowsEngineTest,
       PreparedMemoryRunsAndLaterEnginesCannotMixBase) {
  auto image = fml::FileMapping::CreateReadOnly(AotPath());
  ASSERT_TRUE(image && image->IsValid());
  const auto length = image->GetSize();
  ASSERT_GT(length, 0u);
  const auto first_lease = QueueMemory(
      std::vector<uint8_t>(image->GetMapping(), image->GetMapping() + length),
      kMemorySelection);
  image.reset();

  auto engine = BuildEngine();
  ASSERT_TRUE(engine->Run());
  EXPECT_TRUE(first_lease.expired());
  ExpectDartEntered();
  EXPECT_EQ(engine->view(kImplicitViewId), nullptr);
  engine.reset();

  // A recreated engine must reuse the same loaded selection after both the
  // original input lease and engine have gone. These bytes cannot load an ELF.
  const auto second_lease =
      QueueMemory(std::vector<uint8_t>(length, 0), kMemorySelection);
  engine = BuildEngine();
  ASSERT_TRUE(engine->Run());
  EXPECT_TRUE(second_lease.expired());
  ExpectDartEntered();
  engine.reset();

  // A returned loader refusal for an already running selection must not
  // replace it with the bundled image in another engine.
  QueueMemory({0, 1, 2}, kMemorySelection);
  engine = BuildEngine();
  EXPECT_FALSE(engine->Run());
  engine.reset();
  QueueBase();
  engine = BuildEngine();
  EXPECT_FALSE(engine->Run());
  EXPECT_TRUE(path_loads_.empty());
  EXPECT_TRUE(updater_->aborted.empty());
  EXPECT_EQ(updater_->begun,
            (std::vector<uint64_t>{kMemorySelection, kMemorySelection,
                                   kMemorySelection}));
  EXPECT_EQ(updater_->prepare_count, 4);
}

TEST_F(ShorebirdFlutterWindowsEngineTest,
       RefusedMemoryBeginsBaseBeforeLoadingIt) {
  const auto lease = QueueMemory({0, 1, 2}, kMemorySelection);
  QueueBase();
  auto engine = BuildEngine();
  ASSERT_TRUE(engine->Run());
  ExpectDartEntered();
  EXPECT_TRUE(lease.expired());
  EXPECT_EQ(path_loads_, (std::vector<std::string>{AotPath()}));
  EXPECT_EQ(
      begin_at_path_load_,
      (std::vector<std::vector<uint64_t>>{{kMemorySelection, kBaseSelection}}));
  EXPECT_EQ(updater_->aborted, (std::vector<uint64_t>{kMemorySelection}));
  EXPECT_EQ(updater_->prepare_count, 2);
}

TEST_F(ShorebirdFlutterWindowsEngineTest,
       FailedPreparationNeverLoadsBundledOrLegacyCode) {
  auto engine = BuildEngine();
  EXPECT_FALSE(engine->Run());
  EXPECT_EQ(updater_->prepare_count, 1);
  EXPECT_TRUE(updater_->begun.empty());
  EXPECT_TRUE(updater_->aborted.empty());
  EXPECT_TRUE(path_loads_.empty());
  EXPECT_FALSE(dart_entered_.IsSignaledForTest());
}

TEST_F(ShorebirdFlutterWindowsEngineTest,
       FailedPreparedConfigurationNeverPreparesOrLoadsCode) {
  updater_->RequirePreparedBootSource();
  auto engine = BuildEngine();
  EXPECT_FALSE(engine->Run());
  EXPECT_EQ(updater_->prepare_count, 0);
  EXPECT_TRUE(updater_->begun.empty());
  EXPECT_TRUE(path_loads_.empty());
  EXPECT_FALSE(dart_entered_.IsSignaledForTest());
}

}  // namespace flutter::testing
