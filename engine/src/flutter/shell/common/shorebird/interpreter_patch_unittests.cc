// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/runtime/shorebird/interpreter_patch.h"

#include <algorithm>
#include <array>
#include <cstring>
#include <vector>

#include "gtest/gtest.h"

namespace flutter::shorebird {
namespace {
class Artifact : public fml::Mapping {
 public:
  explicit Artifact(std::string json) : json_(std::move(json)) {}
  const uint8_t* GetMapping() const override {
    return reinterpret_cast<const uint8_t*>(json_.data());
  }
  size_t GetSize() const override { return json_.size(); }
  bool IsDontNeedSafe() const override { return false; }

 private:
  const std::string json_;
};

std::string Envelope(const std::string& key = "test-key") {
  return R"({"metadata":{"flavor_id":"pro","license_type":"pro","runtime_mode":"dart-bytecode-interpreter","patch_snapshot_hash":")" +
         std::string(64, 'b') +
         R"("},"payload_kind":"full-snapshot","encryption":{"key_id":")" + key +
         R"("}})";
}

// A v1 baseline manifest with one root library and a small opaque component.
// The VM owns full component decoding; these tests exercise the engine seam.
std::string ReplacementWrapper() {
  std::string manifest(4, '\0');
  manifest[0] = 1;
  manifest += std::string(32, '\xaa');
  manifest += std::string(64, '\xcc');
  auto uint32 = [](uint32_t value) {
    std::string bytes;
    for (int i = 0; i < 4; ++i) {
      bytes.push_back(static_cast<char>(value >> (i * 8)));
    }
    return bytes;
  };
  const std::string root = "package:app/main.dart";
  manifest += uint32(root.size()) + root;
  manifest += uint32(1) + uint32(root.size()) + root;
  manifest += uint32(1) + uint32(root.size()) + root;
  manifest += uint32(0);
  return std::string("SBRPLCE\0", 8) + uint32(1) + uint32(manifest.size()) +
         uint32(4) + uint32(0) + manifest + "DBC3";
}

class FakeApi : public InterpreterPatchApi {
 public:
  bool install_ok = true;
  bool reload_ok = true;
  bool empty_payload = false;
  Dart_AotPatchKeyCallback callback = nullptr;
  std::vector<std::string> calls;
  std::vector<uint8_t> plaintext = {1, 2, 3, 4};
  bool expect_decrypted_payload = true;
  const uint8_t* reloaded_payload = nullptr;
  intptr_t reloaded_length = 0;

  void SetKeyCallback(Dart_AotPatchKeyCallback value) override {
    calls.emplace_back("callback");
    callback = value;
  }
  bool Install(const fml::Mapping&,
               const Dart_AotPatchInstallOptions& options,
               uint8_t** payload,
               intptr_t* length,
               std::string* error) override {
    calls.emplace_back("install");
    EXPECT_STREQ(options.app_id, "app");
    EXPECT_STREQ(options.app_build_id, "1.0+1");
    EXPECT_STREQ(options.base_flavor_id, "free");
    EXPECT_STREQ(options.base_license_type, "free");
    EXPECT_STREQ(options.flavor_id, "pro");
    EXPECT_STREQ(options.license_type, "pro");
    EXPECT_STREQ(options.runtime_mode, "dart-bytecode-interpreter");
    EXPECT_STREQ(options.target_os, "ios");
    EXPECT_STREQ(options.target_arch, "arm64");
    EXPECT_EQ(std::string(options.patch_snapshot_hash), std::string(64, 'b'));
    std::array<uint8_t, 32> key;
    intptr_t key_length = 0;
    EXPECT_FALSE(callback("wrong-key", key.data(), key.size(), &key_length));
    if (!callback("test-key", key.data(), key.size(), &key_length)) {
      *error = "key unavailable";
      return false;
    }
    EXPECT_EQ(key_length, 32);
    *payload = plaintext.data();
    *length = empty_payload ? 0 : plaintext.size();
    if (!install_ok) {
      *error = "authentication failed";
    }
    return install_ok;
  }
  bool Reload(const uint8_t* payload,
              intptr_t length,
              std::string* error) override {
    calls.emplace_back("reload");
    reloaded_payload = payload;
    reloaded_length = length;
    if (expect_decrypted_payload) {
      EXPECT_EQ(payload, plaintext.data());
      EXPECT_EQ(length, static_cast<intptr_t>(plaintext.size()));
    }
    if (!reload_ok) {
      *error = "bytecode rejected";
    }
    return reload_ok;
  }
  void FreePayload(uint8_t* payload) override {
    calls.emplace_back("free");
    EXPECT_EQ(payload, plaintext.data());
    std::fill(plaintext.begin(), plaintext.end(), 0);
  }
};

class InterpreterPatchTest : public ::testing::Test {
 protected:
  void SetUp() override {
    ResetInterpreterKeyProviderForTesting();
    config.app_id = "app";
    config.app_build_id = "1.0+1";
    config.base_flavor_id = "free";
    config.base_license_type = "free";
    config.flavor_id = "pro";
    config.license_type = "pro";
    config.sdk_hash = "sdk";
    config.base_snapshot_hash = std::string(64, 'a');
    config.key_id = "test-key";
    config.strict_verification = true;
  }
  void TearDown() override { ResetInterpreterKeyProviderForTesting(); }
  void RegisterKey(intptr_t size = 32) {
    ASSERT_TRUE(RegisterInterpreterKeyProvider(
        [size](const char*, uint8_t* buffer, intptr_t, intptr_t* length) {
          std::memset(buffer, 7, 32);
          *length = size;
          return true;
        }));
  }
  bool Apply(const std::string& json = Envelope()) {
    return ApplyInterpreterPatch(config, Artifact(json), api, &error);
  }
  InterpreterPatchConfig config;
  FakeApi api;
  std::string error;
};

TEST_F(InterpreterPatchTest, InstallsThenReloadsAndFreesPlaintext) {
  RegisterKey();
  EXPECT_TRUE(Apply());
  EXPECT_EQ(api.calls, (std::vector<std::string>{"callback", "install",
                                                 "reload", "free"}));
  EXPECT_EQ(api.plaintext, (std::vector<uint8_t>{0, 0, 0, 0}));
  std::array<uint8_t, 32> key;
  intptr_t size;
  // The SDK's process-global callback cannot retrieve keys outside install.
  EXPECT_FALSE(api.callback("test-key", key.data(), key.size(), &size));
}
TEST_F(InterpreterPatchTest, MissingProviderDoesNotDecryptOrExecute) {
  EXPECT_FALSE(Apply());
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterPatchTest, WrongKeySizeDoesNotReload) {
  RegisterKey(16);
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls, (std::vector<std::string>{"callback", "install"}));
}
TEST_F(InterpreterPatchTest, AuthenticationFailureNeverReloadsAndFrees) {
  RegisterKey();
  api.install_ok = false;
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls,
            (std::vector<std::string>{"callback", "install", "free"}));
}
TEST_F(InterpreterPatchTest, ReloadFailureStillFreesPlaintext) {
  RegisterKey();
  api.reload_ok = false;
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls.back(), "free");
  EXPECT_EQ(error, "bytecode rejected");
}
TEST_F(InterpreterPatchTest, EmptyPlaintextNeverReloads) {
  RegisterKey();
  api.empty_payload = true;
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls,
            (std::vector<std::string>{"callback", "install", "free"}));
}
TEST_F(InterpreterPatchTest,
       RejectsNativeAndAmbiguousArtifactsBeforeKeyLookup) {
  RegisterKey();
  EXPECT_FALSE(Apply(std::string("\x7f") + "ELF"));
  EXPECT_FALSE(Apply(R"({"metadata":{},"metadata":{},"encryption":{}})"));
  EXPECT_FALSE(Apply(Envelope("unknown-key")));
  EXPECT_FALSE(Apply(std::string(1000, '[') + "0" + std::string(1000, ']')));
  auto native = Envelope();
  native.replace(native.find("dart-bytecode-interpreter"), 25, "native-aot");
  EXPECT_FALSE(Apply(native));
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterPatchTest, RejectsIncompleteOrUnverifiedBaseline) {
  RegisterKey();
  config.strict_verification = false;
  EXPECT_FALSE(Apply());
  config.strict_verification = true;
  config.base_snapshot_hash.clear();
  EXPECT_FALSE(Apply());
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterPatchTest, AppOwnedKeyCanAuthorizeTargetNotFixedAtRelease) {
  RegisterKey();
  config.flavor_id.clear();
  config.license_type.clear();
  EXPECT_TRUE(Apply());
}
TEST_F(InterpreterPatchTest,
       ExplicitBundleTargetRestrictionCannotBeOverridden) {
  RegisterKey();
  config.flavor_id = "free";
  EXPECT_FALSE(Apply());
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterPatchTest, NewEnginesKeepTheOriginalProcessPatch) {
  auto first = std::make_shared<InterpreterPatchConfig>(config);
  first->path = "patch-1";
  auto next = std::make_shared<InterpreterPatchConfig>(config);
  next->path = "patch-2";
  EXPECT_EQ(SelectInterpreterPatchForProcess(first), first);
  EXPECT_EQ(SelectInterpreterPatchForProcess(next), first);
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), first);
}
TEST_F(InterpreterPatchTest, BackgroundDownloadCannotChangeBaseOnlyProcess) {
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), nullptr);
  auto next = std::make_shared<InterpreterPatchConfig>(config);
  EXPECT_EQ(SelectInterpreterPatchForProcess(next), nullptr);
}
TEST_F(InterpreterPatchTest, FailedBootKeepsLaterEnginesOnCleanBase) {
  auto stale = std::make_shared<InterpreterPatchConfig>(config);
  EXPECT_EQ(SelectInterpreterPatchForProcess(stale), stale);
  RejectInterpreterPatchForProcess();
  EXPECT_EQ(SelectInterpreterPatchForProcess(stale), nullptr);
}
TEST_F(InterpreterPatchTest,
       LaterEngineErrorCannotRollbackAcceptedProcessPatch) {
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  EXPECT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  CompleteInterpreterMainForProcess(true);
  CompleteInterpreterMainForProcess(false);
  EXPECT_FALSE(RejectInterpreterPatchForProcess());
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), patch);
}
TEST_F(InterpreterPatchTest, FailedActualMainPreventsLaterPatchPromotion) {
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  EXPECT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  CompleteInterpreterMainForProcess(false);
  CompleteInterpreterMainForProcess(true);
  EXPECT_EQ(SelectInterpreterPatchForProcess(patch), nullptr);
}
TEST_F(InterpreterPatchTest, ProviderCannotBeReplacedOrInstalledAfterStartup) {
  RegisterKey();
  EXPECT_FALSE(RegisterInterpreterKeyProvider(
      [](const char*, uint8_t*, intptr_t, intptr_t*) { return false; }));
  ResetInterpreterKeyProviderForTesting();
  SealInterpreterKeyProvider();
  EXPECT_FALSE(RegisterInterpreterKeyProvider(
      [](const char*, uint8_t*, intptr_t, intptr_t*) { return false; }));
}

InterpreterReplacementBaseConfig ReplacementBase() {
  InterpreterReplacementBaseConfig base;
  base.path = "/signed/flutter_assets/shorebird_replacement_base.sbr";
  base.host_abi = std::string(64, 'a');
  base.snapshot_hash =
      "0aa96315d2d20ee4c482f75bf8e0ec18ca0457a441bee7f65155e4a597a290c2";
  return base;
}

TEST_F(InterpreterPatchTest, BundledBaseReloadsWithoutEnvelopeOrAesKey) {
  const auto base = ReplacementBase();
  const Artifact artifact(ReplacementWrapper());
  api.expect_decrypted_payload = false;
  EXPECT_TRUE(ApplyInterpreterReplacementBase(base, artifact, api, &error));
  EXPECT_EQ(api.calls, (std::vector<std::string>{"reload"}));
  EXPECT_EQ(api.reloaded_payload, artifact.GetMapping());
  EXPECT_EQ(api.reloaded_length, static_cast<intptr_t>(artifact.GetSize()));
  EXPECT_EQ(std::string(reinterpret_cast<const char*>(artifact.GetMapping()),
                        artifact.GetSize()),
            ReplacementWrapper());
}

TEST_F(InterpreterPatchTest, InvalidBundledBaseNeverTouchesVm) {
  const auto original = ReplacementBase();
  auto base = original;
  base.snapshot_hash[0] = base.snapshot_hash[0] == '0' ? '1' : '0';
  EXPECT_FALSE(ApplyInterpreterReplacementBase(
      base, Artifact(ReplacementWrapper()), api, &error));
  base = original;
  base.host_abi = std::string(64, 'b');
  EXPECT_FALSE(ApplyInterpreterReplacementBase(
      base, Artifact(ReplacementWrapper()), api, &error));
  base = original;
  base.path = "/updater/arbitrary.sbr";
  EXPECT_FALSE(ApplyInterpreterReplacementBase(
      base, Artifact(ReplacementWrapper()), api, &error));
  base = original;
  base.validation_error = "invalid signed configuration";
  EXPECT_FALSE(ApplyInterpreterReplacementBase(
      base, Artifact(ReplacementWrapper()), api, &error));
  EXPECT_TRUE(api.calls.empty());
}

TEST_F(InterpreterPatchTest, RejectsTruncatedWrongVersionAndNonBaseWrappers) {
  const auto base = ReplacementBase();
  auto wrapper = ReplacementWrapper();
  EXPECT_FALSE(ApplyInterpreterReplacementBase(
      base, Artifact(wrapper.substr(0, 23)), api, &error));
  wrapper[8] = 2;
  EXPECT_FALSE(
      ApplyInterpreterReplacementBase(base, Artifact(wrapper), api, &error));
  wrapper = ReplacementWrapper();
  wrapper[16] = 3;
  EXPECT_FALSE(
      ApplyInterpreterReplacementBase(base, Artifact(wrapper), api, &error));
  wrapper = ReplacementWrapper();
  wrapper[24 + 68] = 0;
  EXPECT_FALSE(
      ApplyInterpreterReplacementBase(base, Artifact(wrapper), api, &error));
  EXPECT_TRUE(api.calls.empty());
}

TEST_F(InterpreterPatchTest, FullUpdateForwardsOpaqueWrapperAndFreesIt) {
  RegisterKey();
  config.full_replacement = true;
  config.host_abi = std::string(64, 'a');
  const auto wrapper = ReplacementWrapper();
  api.plaintext.assign(wrapper.begin(), wrapper.end());
  EXPECT_TRUE(Apply());
  EXPECT_EQ(api.reloaded_length, static_cast<intptr_t>(wrapper.size()));
  EXPECT_EQ(api.calls, (std::vector<std::string>{"callback", "install",
                                                 "reload", "free"}));
  EXPECT_TRUE(std::all_of(api.plaintext.begin(), api.plaintext.end(),
                          [](uint8_t byte) { return byte == 0; }));
}

TEST_F(InterpreterPatchTest, ProfileMismatchRejectsBeforeReloadAndStillFrees) {
  RegisterKey();
  config.full_replacement = true;
  config.host_abi = std::string(64, 'a');
  EXPECT_FALSE(Apply());  // DBC3/body profile cannot activate a full baseline.
  EXPECT_EQ(api.calls,
            (std::vector<std::string>{"callback", "install", "free"}));
  api.calls.clear();
  config.full_replacement = false;
  const auto wrapper = ReplacementWrapper();
  api.plaintext.assign(wrapper.begin(), wrapper.end());
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls,
            (std::vector<std::string>{"callback", "install", "free"}));
}

TEST_F(InterpreterPatchTest, UpdateFailureRequiresFreshGroupBeforeBaseInstall) {
  auto base = ReplacementBase();
  config.full_replacement = true;
  config.host_abi = base.host_abi;
  config.base_snapshot_hash = base.snapshot_hash;
  std::vector<std::string> installs;
  auto update = [&] {
    installs.emplace_back("update");
    return false;
  };
  auto bundled = [&] {
    installs.emplace_back("base");
    return true;
  };
  EXPECT_FALSE(InstallInterpreterCodeForFreshGroup(&config, &base, update,
                                                   bundled, &error));
  EXPECT_EQ(installs, (std::vector<std::string>{"update"}));
  // The runtime destroys that group and clears only its optional update.
  EXPECT_TRUE(InstallInterpreterCodeForFreshGroup(nullptr, &base, update,
                                                  bundled, &error));
  EXPECT_EQ(installs, (std::vector<std::string>{"update", "base"}));
}

TEST_F(InterpreterPatchTest, SelectedUpdateDoesNotInstallBaseInSameGroup) {
  auto base = ReplacementBase();
  config.full_replacement = true;
  config.host_abi = base.host_abi;
  config.base_snapshot_hash = base.snapshot_hash;
  int updates = 0;
  int bases = 0;
  EXPECT_TRUE(InstallInterpreterCodeForFreshGroup(
      &config, &base,
      [&] {
        ++updates;
        return true;
      },
      [&] {
        ++bases;
        return true;
      },
      &error));
  EXPECT_EQ(updates, 1);
  EXPECT_EQ(bases, 0);
}

TEST_F(InterpreterPatchTest,
       BrokenBaseOrCompiledProfileCannotFallBackToNativeApp) {
  auto base = ReplacementBase();
  int bases = 0;
  auto bundled = [&] {
    ++bases;
    return false;
  };
  EXPECT_FALSE(InstallInterpreterCodeForFreshGroup(
      nullptr, &base, [] { return true; }, bundled, &error));
  EXPECT_EQ(bases, 1);
  base.validation_error = "broken configuration";
  EXPECT_FALSE(InstallInterpreterCodeForFreshGroup(
      &config, &base, [] { return true; }, bundled, &error));
  EXPECT_EQ(error, "broken configuration");
  EXPECT_EQ(bases, 1);
  base.validation_error.clear();
  // A retained process update from another profile cannot mutate this group.
  EXPECT_FALSE(InstallInterpreterCodeForFreshGroup(
      &config, &base, [] { return true; }, bundled, &error));
  EXPECT_EQ(bases, 1);
}
}  // namespace
}  // namespace flutter::shorebird
