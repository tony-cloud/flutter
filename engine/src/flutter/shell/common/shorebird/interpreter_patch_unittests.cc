// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/runtime/shorebird/interpreter_patch.h"

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

class FakeApi : public InterpreterPatchApi {
 public:
  bool install_ok = true;
  bool reload_ok = true;
  bool empty_payload = false;
  Dart_AotPatchKeyCallback callback = nullptr;
  std::vector<std::string> calls;
  std::array<uint8_t, 4> plaintext = {1, 2, 3, 4};

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
    EXPECT_EQ(payload, plaintext.data());
    EXPECT_EQ(length, 4);
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
  EXPECT_EQ(api.plaintext, (std::array<uint8_t, 4>{0, 0, 0, 0}));
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
TEST_F(InterpreterPatchTest, ProviderCannotBeReplacedOrInstalledAfterStartup) {
  RegisterKey();
  EXPECT_FALSE(RegisterInterpreterKeyProvider(
      [](const char*, uint8_t*, intptr_t, intptr_t*) { return false; }));
  ResetInterpreterKeyProviderForTesting();
  SealInterpreterKeyProvider();
  EXPECT_FALSE(RegisterInterpreterKeyProvider(
      [](const char*, uint8_t*, intptr_t, intptr_t*) { return false; }));
}
}  // namespace
}  // namespace flutter::shorebird
