// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/runtime/shorebird/interpreter_patch.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstring>
#include <future>
#include <vector>

#include "flutter/shell/common/shorebird/updater.h"
#include "gtest/gtest.h"
#include "openssl/sha.h"

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

std::string Envelope(const std::string& key = "test-key",
                     const std::string& target_os = "ios") {
  return R"({"metadata":{"target_os":")" + target_os +
         R"(","target_arch":"arm64","flavor_id":"pro","license_type":"pro","runtime_mode":"dart-bytecode-interpreter","patch_snapshot_hash":")" +
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
  std::string expected_target_os = "ios";
  bool install_ok = true;
  bool reload_ok = true;
  bool empty_payload = false;
  Dart_AotPatchInstallStatus failure_status =
      kDartAotPatchInstallAuthenticationFailed;
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
  bool Install(const fml::Mapping& artifact,
               const Dart_AotPatchInstallOptions& options,
               uint8_t** payload,
               intptr_t* length,
               std::string* error,
               Dart_AotPatchInstallStatus* status) override {
    *status = kDartAotPatchInstallRejected;
    calls.emplace_back("install");
    EXPECT_STREQ(options.app_id, "app");
    EXPECT_STREQ(options.app_build_id, "1.0+1");
    EXPECT_STREQ(options.base_flavor_id, "free");
    EXPECT_STREQ(options.base_license_type, "free");
    EXPECT_STREQ(options.flavor_id, "pro");
    EXPECT_STREQ(options.license_type, "pro");
    EXPECT_STREQ(options.runtime_mode, "dart-bytecode-interpreter");
    EXPECT_STREQ(options.target_os, expected_target_os.c_str());
    EXPECT_STREQ(options.target_arch, "arm64");
    EXPECT_EQ(std::string(options.patch_snapshot_hash), std::string(64, 'b'));
    // Model the SDK's authenticated metadata/expected-target comparison.
    const std::string envelope(
        reinterpret_cast<const char*>(artifact.GetMapping()),
        artifact.GetSize());
    if (envelope.find("\"target_os\":\"" + std::string(options.target_os) +
                      "\"") == std::string::npos) {
      *error = "authenticated target mismatch";
      return false;
    }
    std::array<uint8_t, 32> key;
    intptr_t key_length = 0;
    EXPECT_FALSE(callback("wrong-key", key.data(), key.size(), &key_length));
    if (!callback("test-key", key.data(), key.size(), &key_length)) {
      *error = "key unavailable";
      *status = kDartAotPatchInstallKeyUnavailable;
      return false;
    }
    EXPECT_EQ(key_length, 32);
    *payload = plaintext.data();
    *length = empty_payload ? 0 : plaintext.size();
    if (!install_ok) {
      *error = "authentication failed";
    }
    *status = install_ok ? kDartAotPatchInstallSuccess : failure_status;
    return install_ok;
  }
  bool Reload(const uint8_t* payload,
              intptr_t length,
              std::string* error) override {
    calls.emplace_back("reload");
    if (callback) {
      std::array<uint8_t, 32> key;
      intptr_t key_length = 0;
      EXPECT_FALSE(callback("test-key", key.data(), key.size(), &key_length));
    }
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
    return ApplyInterpreterPatch(config, Artifact(json), api, &error, &status);
  }
  InterpreterPatchConfig config;
  FakeApi api;
  std::string error;
  Dart_AotPatchInstallStatus status = kDartAotPatchInstallRejected;
};

std::string ArtifactDigest(const std::string& bytes) {
  uint8_t digest[SHA256_DIGEST_LENGTH];
  SHA256(reinterpret_cast<const uint8_t*>(bytes.data()), bytes.size(), digest);
  const char* hex = "0123456789abcdef";
  std::string result;
  for (uint8_t byte : digest) {
    result += hex[byte >> 4];
    result += hex[byte & 15];
  }
  return result;
}
std::string V2Envelope() {
  auto envelope = Envelope();
  envelope.insert(envelope.find("\"metadata\":{") + 12,
                  "\"app_id\":\"app\",\"app_build_id\":\"1.0+1\",\"base_"
                  "snapshot_hash\":\"" +
                      std::string(64, 'a') + "\",");
  return envelope;
}
std::string V2Context(const std::string& artifact_hash,
                      const std::string& expiry = "null") {
  return R"({"version":2,"selection_digest":")" + std::string(64, 'c') +
         R"(","selection":{"epoch":"11","scope":{"app_id":"app","release_version":"1.0+1","platform":"ios","arch":"aarch64","client_id_hash":")" +
         std::string(64, 'd') + R"(","base_artifact_hash":")" +
         std::string(64, 'a') +
         R"(","host_abi_hash":null,"runtime_profile":"interpreter-structural"},"channel":"stable","variant_id":"pro","license_type":"pro","entitlement_revision":"grant-7","target":{"kind":"patch","patch_number":"2","artifact_hash":")" +
         artifact_hash +
         R"(","encryption":"artifact-aes-256-gcm","artifact_key_id":"test-key"},"not_before":"0","offline_valid_until":)" +
         expiry +
         R"(,"fallback":{"kind":"base","variant_id":"free","license_type":"free"}}})";
}
class InterpreterSelectionV2Test : public InterpreterPatchTest {
 protected:
  void SetUp() override {
    InterpreterPatchTest::SetUp();
    config.selection_protocol_v2 = true;
    config.selection_id = 42;
    config.patch_number = 2;
    config.release_version = "1.0+1";
    config.runtime_profile = "interpreter-structural";
    // V2 authorizes the selected variant rather than the release's v1 key.
    config.flavor_id = "free";
    config.license_type = "free";
    config.key_id = "obsolete-v1-key";
    config.begin_boot_source = [&] {
      ++begins;
      return begin_ok;
    };
    SetArtifact(V2Envelope());
  }
  void SetArtifact(const std::string& bytes) {
    config.owned_artifact = std::make_shared<Artifact>(bytes);
    config.verified_selection_json = V2Context(ArtifactDigest(bytes));
  }
  void RegisterV2() {
    ASSERT_TRUE(RegisterInterpreterKeyProviderV2(
        [&](const char* key, const std::string& context, uint8_t* buffer,
            intptr_t, intptr_t* length) {
          EXPECT_EQ(begins, 1);
          EXPECT_STREQ(key, "test-key");
          EXPECT_EQ(context, config.verified_selection_json);
          ++key_calls;
          std::memset(buffer, 7, 32);
          *length = 32;
          return true;
        }));
  }
  bool ApplyV2() {
    return ApplyInterpreterPatch(config, *config.owned_artifact, api, &error,
                                 &status);
  }
  int begins = 0;
  int key_calls = 0;
  bool begin_ok = true;
};
TEST_F(InterpreterSelectionV2Test,
       BeginsSameTokenBeforeSelectionAwareKeyRelease) {
  RegisterV2();
  EXPECT_TRUE(ApplyV2()) << error;
  EXPECT_EQ(begins, 1);
  EXPECT_EQ(key_calls, 1);
  std::array<uint8_t, 32> key;
  intptr_t length = 0;
  EXPECT_FALSE(api.callback("test-key", key.data(), key.size(), &length));
}
TEST_F(InterpreterSelectionV2Test, V2NeverFallsBackToLegacyProvider) {
  RegisterKey();
  EXPECT_FALSE(ApplyV2());
  EXPECT_EQ(status, kDartAotPatchInstallKeyUnavailable);
  EXPECT_EQ(begins, 1);
  EXPECT_EQ(key_calls, 0);
}
TEST_F(InterpreterSelectionV2Test, StaleTokenDoesNotReleaseKeyOrTouchVm) {
  RegisterV2();
  begin_ok = false;
  EXPECT_FALSE(ApplyV2());
  EXPECT_EQ(begins, 1);
  EXPECT_EQ(key_calls, 0);
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterSelectionV2Test,
       MissingContextNeverBeginsOrCallsKeyProvider) {
  RegisterV2();
  config.verified_selection_json.clear();
  EXPECT_FALSE(ApplyV2());
  EXPECT_EQ(begins, 0);
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterSelectionV2Test,
       ArtifactMutationCannotReuseVerifiedAuthority) {
  RegisterV2();
  auto changed = V2Envelope() + " ";
  config.owned_artifact = std::make_shared<Artifact>(changed);
  EXPECT_FALSE(ApplyV2());
  EXPECT_EQ(begins, 0);
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterSelectionV2Test,
       RejectsReplayProfileLeaseAndAmbiguousContext) {
  RegisterV2();
  const auto original = config.verified_selection_json;
  for (const auto& pair : std::vector<std::pair<std::string, std::string>>{
           {"\"platform\":\"ios\"", "\"platform\":\"macos\""},
           {"\"runtime_profile\":\"interpreter-structural\"",
            "\"runtime_profile\":\"interpreter-full\""},
           {"\"variant_id\":\"pro\"", "\"variant_id\":\"enterprise\""},
           {"\"artifact_key_id\":\"test-key\"",
            "\"artifact_key_id\":\"other\""},
           {"\"offline_valid_until\":null", "\"offline_valid_until\":\"1\""},
           {"\"epoch\":\"11\"", "\"epoch\":\"11\",\"epoch\":\"11\""},
           {"\"version\":2", "\"version\":2,\"unknown\":true"}}) {
    config.verified_selection_json = original;
    const auto position = config.verified_selection_json.find(pair.first);
    ASSERT_NE(position, std::string::npos);
    config.verified_selection_json.replace(position, pair.first.size(),
                                           pair.second);
    EXPECT_FALSE(ApplyV2()) << pair.second;
    EXPECT_EQ(begins, 0);
    EXPECT_TRUE(api.calls.empty());
  }
}
TEST_F(InterpreterSelectionV2Test, WireAarch64NeverAcceptsX64EnvelopeMetadata) {
  RegisterV2();
  auto bytes = V2Envelope();
  bytes.replace(bytes.find("arm64"), 5, "x64");
  SetArtifact(bytes);
  EXPECT_FALSE(ApplyV2());
  EXPECT_EQ(begins, 0);
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterSelectionV2Test, BegunAuthorityKeepsLaterEnginesCoherent) {
  RegisterV2();
  // Model an already-begun, process-owned source whose original grant now
  // passes its lease boundary. Revalidation must not choose another variant.
  config.boot_source_begun->store(true);
  config.verified_selection_json =
      V2Context(ArtifactDigest(V2Envelope()), "\"1\"");
  EXPECT_TRUE(ApplyV2()) << error;
  EXPECT_EQ(begins, 1);
}
TEST_F(InterpreterSelectionV2Test,
       ConcurrentBaseWinDiscardsInstalledPatchBeforeMain) {
  std::atomic<int> begins{0};
  config.begin_boot_source = [&] {
    ++begins;
    return true;
  };
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  ASSERT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  std::promise<void> first_in_provider;
  std::promise<void> release_first;
  auto released = release_first.get_future().share();
  std::atomic<int> key_calls{0};
  std::atomic<int> patch_mains{0};
  ASSERT_TRUE(RegisterInterpreterKeyProviderV2(
      [&](const char*, const std::string&, uint8_t* buffer, intptr_t,
          intptr_t* length) {
        // Application callbacks can re-enter provider/selection APIs. No
        // process commitment/provider mutex may be held across this call.
        EXPECT_EQ(SelectInterpreterPatchForProcess(patch), patch);
        SealInterpreterKeyProvider();
        EXPECT_FALSE(RegisterInterpreterKeyProviderV2({}));
        if (key_calls.fetch_add(1) == 0) {
          first_in_provider.set_value();
          released.wait();
          std::memset(buffer, 7, 32);
          *length = 32;
          return true;
        }
        return false;
      }));
  auto first = std::async(std::launch::async, [&] {
    FakeApi first_api;
    std::string first_error;
    Dart_AotPatchInstallStatus first_status;
    const bool installed = ApplyInterpreterPatch(
        *patch, *patch->owned_artifact, first_api, &first_error, &first_status);
    EXPECT_TRUE(installed) << first_error;
    if (!installed || !CommitInterpreterSourceForProcess(patch.get()))
      return false;
    ++patch_mains;
    CompleteInterpreterMainForProcess(true);
    return true;
  });
  first_in_provider.get_future().wait();
  FakeApi second_api;
  std::string second_error;
  Dart_AotPatchInstallStatus second_status;
  EXPECT_FALSE(ApplyInterpreterPatch(*patch, *patch->owned_artifact, second_api,
                                     &second_error, &second_status));
  EXPECT_EQ(second_status, kDartAotPatchInstallKeyUnavailable);
  int aborts = 0;
  EXPECT_TRUE(RejectInterpreterPatchForProcess([&] { ++aborts; }));
  EXPECT_TRUE(CommitInterpreterSourceForProcess(nullptr));
  int base_mains = 0;
  ++base_mains;
  CompleteInterpreterMainForProcess(true);
  release_first.set_value();
  EXPECT_FALSE(first.get());
  EXPECT_EQ(begins, 2);
  EXPECT_EQ(aborts, 1);
  EXPECT_EQ(patch_mains, 0);
  EXPECT_EQ(base_mains, 1);
  EXPECT_EQ(SelectInterpreterPatchForProcess(patch), nullptr);
  // The discarded group may recreate only the same committed BASE.
  EXPECT_TRUE(RejectInterpreterPatchForProcess([&] { ++aborts; }));
  EXPECT_TRUE(CommitInterpreterSourceForProcess(nullptr));
  EXPECT_EQ(aborts, 1);
}
TEST_F(InterpreterSelectionV2Test,
       ConcurrentPatchCommitPreventsBaseBeforeMainCompletes) {
  std::atomic<int> begins{0};
  config.begin_boot_source = [&] {
    ++begins;
    return true;
  };
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  ASSERT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  std::promise<void> first_in_provider;
  std::promise<void> release_first;
  auto released = release_first.get_future().share();
  std::atomic<int> key_calls{0};
  std::atomic<int> aborts{0};
  ASSERT_TRUE(RegisterInterpreterKeyProviderV2(
      [&](const char*, const std::string&, uint8_t* buffer, intptr_t,
          intptr_t* length) {
        EXPECT_EQ(SelectInterpreterPatchForProcess(patch), patch);
        SealInterpreterKeyProvider();
        if (key_calls.fetch_add(1) == 0) {
          first_in_provider.set_value();
          released.wait();
          return false;
        }
        std::memset(buffer, 7, 32);
        *length = 32;
        return true;
      }));
  auto refusing_engine = std::async(std::launch::async, [&] {
    FakeApi refusing_api;
    std::string refusing_error;
    Dart_AotPatchInstallStatus refusing_status;
    EXPECT_FALSE(ApplyInterpreterPatch(*patch, *patch->owned_artifact,
                                       refusing_api, &refusing_error,
                                       &refusing_status));
    EXPECT_EQ(refusing_status, kDartAotPatchInstallKeyUnavailable);
    return RejectInterpreterPatchForProcess([&] { ++aborts; });
  });
  first_in_provider.get_future().wait();
  FakeApi installing_api;
  std::string installing_error;
  Dart_AotPatchInstallStatus installing_status;
  EXPECT_TRUE(ApplyInterpreterPatch(*patch, *patch->owned_artifact,
                                    installing_api, &installing_error,
                                    &installing_status));
  EXPECT_TRUE(CommitInterpreterSourceForProcess(patch.get()));
  // Main has not completed yet. Commitment alone must exclude BASE.
  release_first.set_value();
  EXPECT_FALSE(refusing_engine.get());
  EXPECT_EQ(aborts, 0);
  EXPECT_FALSE(CommitInterpreterSourceForProcess(nullptr));
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), patch);
  CompleteInterpreterMainForProcess(true);
  EXPECT_TRUE(CommitInterpreterSourceForProcess(patch.get()));
  EXPECT_FALSE(RejectInterpreterPatchForProcess([&] { ++aborts; }));
  EXPECT_EQ(aborts, 0);
  EXPECT_EQ(begins, 2);
}
TEST_F(InterpreterSelectionV2Test,
       UnreadableOwnedArtifactIsRetryableWithoutForgedKeyStatus) {
  config.owned_artifact.reset();
  config.owned_artifact_read_failed = true;
  EXPECT_EQ(LoadOwnedInterpreterArtifact("/missing/owned-interpreter-artifact"),
            nullptr);
  EXPECT_TRUE(
      IsInterpreterPatchRetryableFailure(config, kDartAotPatchInstallRejected));
  EXPECT_FALSE(IsInterpreterPatchKeyFailure(kDartAotPatchInstallRejected));
  config.owned_artifact_read_failed = false;
  EXPECT_FALSE(
      IsInterpreterPatchRetryableFailure(config, kDartAotPatchInstallRejected));
  config.selection_protocol_v2 = false;
  config.owned_artifact_read_failed = true;
  EXPECT_FALSE(
      IsInterpreterPatchRetryableFailure(config, kDartAotPatchInstallRejected));
}
TEST_F(InterpreterSelectionV2Test, WrongProvisionedKeyRetainsTypedDeferral) {
  RegisterV2();
  api.install_ok = false;
  EXPECT_FALSE(ApplyV2());
  EXPECT_EQ(status, kDartAotPatchInstallAuthenticationFailed);
  EXPECT_TRUE(IsInterpreterPatchKeyFailure(status));
  EXPECT_EQ(api.calls.back(), "free");
}

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
TEST_F(InterpreterPatchTest, MacOSUsesTrustedPlatformInSdkOptions) {
  RegisterKey();
  config.target = InterpreterPatchTarget::kMacOSArm64;
  api.expected_target_os = "macos";
  EXPECT_TRUE(Apply(Envelope("test-key", "macos")));
}
TEST_F(InterpreterPatchTest,
       MacOSRejectsAuthenticatedIosArtifactWithoutReload) {
  RegisterKey();
  config.target = InterpreterPatchTarget::kMacOSArm64;
  api.expected_target_os = "macos";
  EXPECT_FALSE(Apply());
  EXPECT_EQ(error, "authenticated target mismatch");
  EXPECT_EQ(api.calls, (std::vector<std::string>{"callback", "install"}));
}
TEST_F(InterpreterPatchTest, InvalidTrustedTargetNeverCallsSdk) {
  RegisterKey();
  config.target = static_cast<InterpreterPatchTarget>(99);
  EXPECT_FALSE(Apply());
  EXPECT_TRUE(api.calls.empty());
}
TEST_F(InterpreterPatchTest, MissingProviderDoesNotDecryptOrExecute) {
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls, (std::vector<std::string>{"callback", "install"}));
  EXPECT_EQ(status, kDartAotPatchInstallKeyUnavailable);
}
TEST_F(InterpreterPatchTest, WrongKeySizeDoesNotReload) {
  RegisterKey(16);
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls, (std::vector<std::string>{"callback", "install"}));
  EXPECT_TRUE(IsInterpreterPatchKeyFailure(status));
}
TEST_F(InterpreterPatchTest, AuthenticationFailureNeverReloadsAndFrees) {
  RegisterKey();
  api.install_ok = false;
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls,
            (std::vector<std::string>{"callback", "install", "free"}));
  EXPECT_EQ(status, kDartAotPatchInstallAuthenticationFailed);
  EXPECT_TRUE(IsInterpreterPatchKeyFailure(status));
}
TEST_F(InterpreterPatchTest, ReloadFailureStillFreesPlaintext) {
  RegisterKey();
  api.reload_ok = false;
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls.back(), "free");
  EXPECT_EQ(error, "bytecode rejected");
  EXPECT_EQ(status, kDartAotPatchInstallRejected);
  EXPECT_FALSE(IsInterpreterPatchKeyFailure(status));
}

TEST_F(InterpreterPatchTest, OnlyTypedKeyRefusalsAreRetryable) {
  RegisterKey();
  api.install_ok = false;
  api.failure_status = kDartAotPatchInstallRejected;
  // Even the same diagnostic text must not control persistent retry policy.
  EXPECT_FALSE(Apply());
  EXPECT_EQ(error, "authentication failed");
  EXPECT_EQ(status, kDartAotPatchInstallRejected);
  EXPECT_FALSE(IsInterpreterPatchKeyFailure(status));
  api.failure_status = static_cast<Dart_AotPatchInstallStatus>(99);
  EXPECT_FALSE(Apply());
  EXPECT_EQ(status, kDartAotPatchInstallRejected);
  EXPECT_FALSE(IsInterpreterPatchKeyFailure(status));
}

TEST_F(InterpreterPatchTest, ValidationRejectionClearsPriorRetryableStatus) {
  EXPECT_FALSE(Apply());
  EXPECT_TRUE(IsInterpreterPatchKeyFailure(status));
  EXPECT_FALSE(Apply(Envelope("wrong-key")));
  EXPECT_EQ(status, kDartAotPatchInstallRejected);
}
TEST_F(InterpreterPatchTest, EmptyPlaintextNeverReloads) {
  RegisterKey();
  api.empty_payload = true;
  EXPECT_FALSE(Apply());
  EXPECT_EQ(api.calls,
            (std::vector<std::string>{"callback", "install", "free"}));
  EXPECT_EQ(status, kDartAotPatchInstallRejected);
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

TEST_F(InterpreterPatchTest, BaseSelectionWaitsForKeyDeferralBookkeeping) {
  for (bool persisted : {false, true}) {
    ResetInterpreterKeyProviderForTesting();
    Updater::ResetLaunchStateForTesting();
    MockUpdater updater;
    ASSERT_TRUE(updater.Init(AppConfig{}));
    updater.set_should_auto_update(true);
    updater.set_launch_deferred_result(persisted);
    updater.ReportLaunchStart();
    auto patch = std::make_shared<InterpreterPatchConfig>(config);
    patch->path = "encrypted-patch";
    ASSERT_EQ(SelectInterpreterPatchForProcess(patch), patch);

    // Pause engine A exactly before it claims/finalizes the updater outcome.
    // Engine B has an independent UI runner and tries to select/run BASE in
    // this window. It must remain blocked until bookkeeping has finished.
    std::promise<void> reporting;
    std::promise<void> finish_reporting;
    auto finish = finish_reporting.get_future();
    auto rejection = std::async(std::launch::async, [&] {
      return RejectInterpreterPatchForProcess([&] {
        reporting.set_value();
        finish.wait();
        EXPECT_EQ(updater.ReportLaunchDeferred(patch->path), persisted);
      });
    });
    reporting.get_future().wait();
    std::promise<void> selecting;
    auto base_engine = std::async(std::launch::async, [&] {
      selecting.set_value();
      EXPECT_EQ(SelectInterpreterPatchForProcess(patch), nullptr);
      CompleteInterpreterMainForProcess(true,
                                        [&] { updater.ReportLaunchSuccess(); });
    });
    selecting.get_future().wait();
    EXPECT_EQ(base_engine.wait_for(std::chrono::milliseconds(100)),
              std::future_status::timeout);
    finish_reporting.set_value();
    EXPECT_TRUE(rejection.get());
    base_engine.get();
    EXPECT_EQ(updater.launch_deferred_count(), 1);
    EXPECT_EQ(updater.launch_success_count(), 0);
    EXPECT_EQ(updater.launch_failure_count(), 0);
    EXPECT_EQ(updater.start_update_thread_count(), persisted ? 1 : 0);
  }
  Updater::ResetLaunchStateForTesting();
}

TEST_F(InterpreterPatchTest, PermanentRejectionIsReportedBeforeBaseSelection) {
  Updater::ResetLaunchStateForTesting();
  MockUpdater updater;
  ASSERT_TRUE(updater.Init(AppConfig{}));
  updater.set_should_auto_update(true);
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  ASSERT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  ASSERT_TRUE(
      RejectInterpreterPatchForProcess([&] { updater.ReportLaunchFailure(); }));
  EXPECT_EQ(SelectInterpreterPatchForProcess(patch), nullptr);
  CompleteInterpreterMainForProcess(true,
                                    [&] { updater.ReportLaunchSuccess(); });
  EXPECT_EQ(updater.launch_failure_count(), 1);
  EXPECT_EQ(updater.launch_success_count(), 0);
  EXPECT_EQ(updater.launch_deferred_count(), 0);
  EXPECT_EQ(updater.start_update_thread_count(), 1);
  Updater::ResetLaunchStateForTesting();
}

TEST_F(InterpreterPatchTest, CompletedMainWinsBeforeConcurrentKeyRejection) {
  Updater::ResetLaunchStateForTesting();
  MockUpdater updater;
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  ASSERT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  std::promise<void> reporting;
  std::promise<void> finish_reporting;
  auto finish = finish_reporting.get_future();
  auto main = std::async(std::launch::async, [&] {
    CompleteInterpreterMainForProcess(true, [&] {
      reporting.set_value();
      finish.wait();
      updater.ReportLaunchSuccess();
    });
  });
  reporting.get_future().wait();
  std::promise<void> rejecting;
  auto rejection = std::async(std::launch::async, [&] {
    rejecting.set_value();
    return RejectInterpreterPatchForProcess(
        [&] { updater.ReportLaunchDeferred(patch->path); });
  });
  rejecting.get_future().wait();
  EXPECT_EQ(rejection.wait_for(std::chrono::milliseconds(100)),
            std::future_status::timeout);
  finish_reporting.set_value();
  main.get();
  EXPECT_FALSE(rejection.get());
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), patch);
  EXPECT_EQ(updater.launch_success_count(), 1);
  EXPECT_EQ(updater.launch_deferred_count(), 0);
  Updater::ResetLaunchStateForTesting();
}

TEST_F(InterpreterPatchTest,
       CompletedMainWinsBeforeConcurrentEntrypointFailure) {
  Updater::ResetLaunchStateForTesting();
  MockUpdater updater;
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  ASSERT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  std::promise<void> reporting;
  std::promise<void> finish_reporting;
  auto finish = finish_reporting.get_future();
  auto main = std::async(std::launch::async, [&] {
    CompleteInterpreterMainForProcess(true, [&] {
      reporting.set_value();
      finish.wait();
      updater.ReportLaunchSuccess();
    });
  });
  reporting.get_future().wait();
  std::promise<void> failing_entrypoint;
  auto failure = std::async(std::launch::async, [&] {
    failing_entrypoint.set_value();
    // The RunFromLibrary failure path uses this ordered rejection, too.
    return RejectInterpreterPatchForProcess(
        [&] { updater.ReportLaunchFailure(); });
  });
  failing_entrypoint.get_future().wait();
  EXPECT_EQ(failure.wait_for(std::chrono::milliseconds(100)),
            std::future_status::timeout);
  finish_reporting.set_value();
  main.get();
  EXPECT_FALSE(failure.get());
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), patch);
  EXPECT_EQ(updater.launch_success_count(), 1);
  EXPECT_EQ(updater.launch_failure_count(), 0);
  Updater::ResetLaunchStateForTesting();
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
TEST_F(InterpreterPatchTest,
       FailedCommittedMainRefusesFreshGroupsUntilColdRestart) {
  auto patch = std::make_shared<InterpreterPatchConfig>(config);
  EXPECT_EQ(SelectInterpreterPatchForProcess(patch), patch);
  EXPECT_TRUE(CommitInterpreterSourceForProcess(patch.get()));
  int failures = 0;
  CompleteInterpreterMainForProcess(false, [&] { ++failures; });
  EXPECT_EQ(failures, 1);
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), patch);
  EXPECT_FALSE(CommitInterpreterSourceForProcess(patch.get()));
  EXPECT_FALSE(CommitInterpreterSourceForProcess(nullptr));
  EXPECT_FALSE(RejectInterpreterPatchForProcess());
  CompleteInterpreterMainForProcess(true);
  EXPECT_FALSE(CommitInterpreterSourceForProcess(patch.get()));
}
TEST_F(InterpreterPatchTest, CommittedBaseFailureCannotRetryAnotherSource) {
  EXPECT_EQ(SelectInterpreterPatchForProcess(nullptr), nullptr);
  EXPECT_TRUE(CommitInterpreterSourceForProcess(nullptr));
  CompleteInterpreterMainForProcess(false);
  EXPECT_FALSE(CommitInterpreterSourceForProcess(nullptr));
  EXPECT_FALSE(RejectInterpreterPatchForProcess());
  EXPECT_EQ(SelectInterpreterPatchForProcess(
                std::make_shared<InterpreterPatchConfig>(config)),
            nullptr);
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
  EXPECT_EQ(status, kDartAotPatchInstallRejected);
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
