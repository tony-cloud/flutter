// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/shell/common/shorebird/shorebird.h"

#include <algorithm>
#include <cstdio>
#include <cstring>
#include <limits>
#include <mutex>
#include <set>
#include <sstream>
#include <vector>

#include "flutter/fml/build_config.h"
#include "flutter/fml/paths.h"
#if FML_OS_WIN
#include "flutter/fml/platform/win/wstring_conversion.h"
#endif
#include "flutter/runtime/shorebird/interpreter_patch.h"
#include "flutter/shell/common/shorebird/updater.h"
#include "rapidjson/document.h"

namespace flutter {

// Given the contents of a yaml file, return the given value if it exists,
// otherwise return an empty string.
// Does not support nested keys.
std::string GetValueFromYaml(const std::string& yaml, const std::string& key) {
  std::stringstream input(yaml);
  std::string line;
  const std::string prefix = key + ":";
  while (std::getline(input, line)) {
    // The compiler emits a flat mapping. Match complete keys, not substrings
    // in another key, a comment, or an attacker-controlled scalar value.
    if (line.compare(0, prefix.size(), prefix) != 0) {
      continue;
    }
    auto value = line.substr(prefix.size());
    auto begin = value.find_first_not_of(" \t\r");
    if (begin == std::string::npos) {
      return "";
    }
    value = value.substr(begin, value.find_last_not_of(" \t\r") - begin + 1);
    if (value.front() == '"') {
      rapidjson::Document scalar;
      scalar.Parse(value.c_str());
      if (!scalar.HasParseError() && scalar.IsString() &&
          std::strlen(scalar.GetString()) == scalar.GetStringLength()) {
        return scalar.GetString();
      }
      return "";
    }
    if (value.front() == '\'') {
      if (value.size() < 2 || value.back() != '\'') {
        return "";
      }
      value = value.substr(1, value.size() - 2);
      size_t offset = 0;
      while ((offset = value.find("''", offset)) != std::string::npos) {
        value.replace(offset, 2, "'");
        ++offset;
      }
    }
    return value;
  }
  return "";
}

bool ResolveNativePatchMaxBytes(const std::string& compiled_yaml,
                                uint64_t explicit_max_bytes,
                                uint64_t& max_bytes) {
  constexpr auto limit =
      static_cast<uint64_t>(std::numeric_limits<int64_t>::max());
  max_bytes = 0;
  if (explicit_max_bytes > limit) {
    return false;
  }
  const std::string key = "native_patch_max_bytes";
  const auto prefix = key + ":";
  std::stringstream input(compiled_yaml);
  std::string line;
  size_t count = 0;
  while (std::getline(input, line)) {
    count += line.compare(0, prefix.size(), prefix) == 0;
  }
  if (count == 0) {
    max_bytes =
        explicit_max_bytes ? explicit_max_bytes : kDefaultNativePatchMaxBytes;
    return true;
  }
  const auto value = GetValueFromYaml(compiled_yaml, key);
  if (count != 1 || value.empty()) {
    return false;
  }
  uint64_t parsed = 0;
  for (const auto digit : value) {
    if (digit < '0' || digit > '9' || parsed > (limit - (digit - '0')) / 10) {
      return false;
    }
    parsed = parsed * 10 + (digit - '0');
  }
  if (parsed == 0 || (explicit_max_bytes && explicit_max_bytes != parsed)) {
    return false;
  }
  max_bytes = parsed;
  return true;
}

namespace {
constexpr size_t kMaximumInterpreterArtifactBytes = 256 * 1024 * 1024;
std::mutex baseline_mutex;
std::string baseline_identity;
std::shared_ptr<const std::vector<uint8_t>> baseline_bytes;
struct BaselineStream {
  std::shared_ptr<const std::vector<uint8_t>> bytes;
  size_t position = 0;
};
void* OpenReleaseBaseline() {
  std::lock_guard<std::mutex> lock(baseline_mutex);
  return baseline_bytes ? new BaselineStream{baseline_bytes} : nullptr;
}
uintptr_t ReadReleaseBaseline(void* handle, uint8_t* buffer, uintptr_t length) {
  auto* stream = static_cast<BaselineStream*>(handle);
  const size_t count =
      std::min<size_t>(length, stream->bytes->size() - stream->position);
  std::memcpy(buffer, stream->bytes->data() + stream->position, count);
  stream->position += count;
  return count;
}
int64_t SeekReleaseBaseline(void* handle, int64_t offset, int32_t whence) {
  auto* stream = static_cast<BaselineStream*>(handle);
  int64_t origin;
  if (whence == SEEK_SET) {
    origin = 0;
  } else if (whence == SEEK_CUR) {
    origin = stream->position;
  } else if (whence == SEEK_END) {
    origin = stream->bytes->size();
  } else {
    return -1;
  }
  if (offset < -origin ||
      offset > static_cast<int64_t>(stream->bytes->size()) - origin) {
    return -1;
  }
  stream->position = origin + offset;
  return stream->position;
}
void CloseReleaseBaseline(void* handle) {
  delete static_cast<BaselineStream*>(handle);
}
bool ReadOwnedFile(const std::string& path,
                   size_t limit,
                   std::vector<uint8_t>* bytes) {
#if FML_OS_WIN
  FILE* opened = _wfopen(fml::Utf8ToWideString(path).c_str(), L"rb");
#else
  FILE* opened = std::fopen(path.c_str(), "rb");
#endif
  std::unique_ptr<FILE, decltype(&std::fclose)> file(opened, std::fclose);
  if (!file || std::fseek(file.get(), 0, SEEK_END) != 0)
    return false;
  const long length = std::ftell(file.get());
  if (length <= 0 || static_cast<uint64_t>(length) > limit ||
      std::fseek(file.get(), 0, SEEK_SET) != 0)
    return false;
  bytes->resize(length);
  return std::fread(bytes->data(), 1, bytes->size(), file.get()) ==
             bytes->size() &&
         std::fgetc(file.get()) == EOF;
}
}  // namespace

bool RequireSelectionV2IfMarked(const std::string& yaml) {
  std::stringstream lines(yaml);
  std::string line;
  size_t count = 0;
  while (std::getline(lines, line)) {
    count += line.compare(0, 19, "selection_protocol:") == 0;
  }
  if (count == 0 ||
      (count == 1 && GetValueFromYaml(yaml, "selection_protocol") == "1")) {
    return false;
  }
  shorebird::Updater::Instance().RequireSelectionV2();
  return true;
}

std::string ShorebirdHostArch() {
#if FML_ARCH_CPU_ARM64
  return "aarch64";
#elif FML_ARCH_CPU_ARMEL
  return "arm";
#elif FML_ARCH_CPU_X86
  return "x86";
#elif FML_ARCH_CPU_X86_64
  return "x86_64";
#else
  return "";
#endif
}
std::string ReleaseScopeAssetName(const std::string& platform,
                                  const std::string& arch) {
  if ((platform != "android" && platform != "ios" && platform != "macos" &&
       platform != "linux" && platform != "windows") ||
      (arch != "arm" && arch != "aarch64" && arch != "x86" &&
       arch != "x86_64")) {
    return "";
  }
  return "shorebird_release_scope_" + platform + "_" + arch + ".json";
}

bool LoadCompiledReleaseScopeAsset(
    const std::string& platform,
    const std::string& arch,
    const std::function<std::unique_ptr<fml::Mapping>(const std::string&)>&
        load,
    std::string* scope_json) {
  if (!scope_json)
    return false;
  scope_json->clear();
  const auto name = ReleaseScopeAssetName(platform, arch);
  if (name.empty() || !load)
    return false;
  auto mapping = load(name);
  if (!mapping)
    return false;
  const auto length = mapping->GetSize();
  if (length == 0 || length > 64 * 1024)
    return false;
  const auto* bytes = mapping->GetMapping();
  if (!bytes)
    return false;
  scope_json->assign(reinterpret_cast<const char*>(bytes), length);
  return true;
}

bool ValidateAndroidNativeReleaseLibraryPaths(
    const std::vector<std::string>& paths) {
  constexpr char suffix[] = "/libapp.so";
  return paths.size() == 2 && paths[0] == "libapp.so" && !paths[1].empty() &&
         paths[1][0] == '/' && paths[1].size() > sizeof(suffix) - 1 &&
         paths[1].compare(paths[1].size() - (sizeof(suffix) - 1),
                          sizeof(suffix) - 1, suffix) == 0 &&
         paths[1].find("/../") == std::string::npos &&
         paths[1].find("/./") == std::string::npos &&
         paths[1].find('\0') == std::string::npos;
}

void ResetSelectionV2BaselineForTesting() {
  std::lock_guard<std::mutex> lock(baseline_mutex);
  baseline_identity.clear();
  baseline_bytes.reset();
}

bool ConfigureSelectionV2(shorebird::AppConfig& config,
                          const std::string& assets_path,
                          const std::string& platform,
                          const std::string& arch,
                          const std::string* compiled_scope_json) {
  std::stringstream lines(config.yaml_config);
  std::string line;
  size_t count = 0;
  while (std::getline(lines, line)) {
    count += line.compare(0, 19, "selection_protocol:") == 0;
  }
  if (count == 0)
    return true;
  const auto protocol =
      GetValueFromYaml(config.yaml_config, "selection_protocol");
  if (count == 1 && protocol == "1")
    return true;
  config.selection_protocol_v2 = true;
  shorebird::Updater::Instance().RequireSelectionV2();
  const auto asset_name = ReleaseScopeAssetName(platform, arch);
  if (count != 1 || protocol != "2" || asset_name.empty())
    return false;
  std::vector<uint8_t> bytes;
  if (compiled_scope_json) {
    if (compiled_scope_json->empty() || compiled_scope_json->size() > 64 * 1024)
      return false;
    bytes.assign(compiled_scope_json->begin(), compiled_scope_json->end());
  } else if (assets_path.empty() ||
             !ReadOwnedFile(fml::paths::JoinPaths({assets_path, asset_name}),
                            64 * 1024, &bytes)) {
    return false;
  }
  if (std::find(bytes.begin(), bytes.end(), 0) != bytes.end())
    return false;
  rapidjson::Document scope;
  scope.Parse<rapidjson::kParseValidateEncodingFlag>(
      reinterpret_cast<const char*>(bytes.data()), bytes.size());
  if (scope.HasParseError() || !scope.IsObject() || scope.MemberCount() != 7)
    return false;
  std::set<std::string> fields;
  for (auto it = scope.MemberBegin(); it != scope.MemberEnd(); ++it) {
    if (!fields.emplace(it->name.GetString(), it->name.GetStringLength())
             .second)
      return false;
  }
  if (fields != std::set<std::string>{"app_id", "release_version", "platform",
                                      "arch", "base_artifact_hash",
                                      "host_abi_hash", "runtime_profile"})
    return false;
  auto text = [&](const char* name) -> std::string {
    const auto& value = scope[name];
    return value.IsString() &&
                   std::strlen(value.GetString()) == value.GetStringLength()
               ? value.GetString()
               : "";
  };
  const auto profile = text("runtime_profile");
  if ((platform == "android" || platform == "linux" || platform == "windows") &&
      profile != "native-aot")
    return false;
  const bool full = profile == "interpreter-full";
  const bool interpreter = full || profile == "interpreter-body" ||
                           profile == "interpreter-structural";
  // macOS executes the signed full-replacement host only. Body/structural
  // routing and 32-bit hosts have no supported signed interpreter entrypoint.
  if (platform == "macos" && interpreter &&
      (!full || (arch != "aarch64" && arch != "x86_64")))
    return false;
  if (text("app_id") != GetValueFromYaml(config.yaml_config, "app_id") ||
      text("release_version") != config.release_version ||
      text("platform") != platform || text("arch") != arch ||
      (!interpreter && profile != "native-aot") ||
      (full ? text("host_abi_hash") !=
                  GetValueFromYaml(config.yaml_config, "aot_patch_host_abi")
            : !scope["host_abi_hash"].IsNull()))
    return false;
  if (!interpreter) {
    const auto mode =
        GetValueFromYaml(config.yaml_config, "aot_patch_runtime_mode");
    if ((!mode.empty() && mode != "native-aot") ||
        GetValueFromYaml(config.yaml_config, "aot_patch_full_replacement") ==
            "true" ||
        GetValueFromYaml(config.yaml_config, "aot_patch_structural_updates") ==
            "true")
      return false;
  }
  if (interpreter) {
    if (text("base_artifact_hash") !=
            GetValueFromYaml(config.yaml_config,
                             "aot_patch_base_snapshot_hash") ||
        GetValueFromYaml(config.yaml_config, "aot_patch_runtime_mode") !=
            "dart-bytecode-interpreter" ||
        (GetValueFromYaml(config.yaml_config, "aot_patch_full_replacement") ==
         "true") != full ||
        (GetValueFromYaml(config.yaml_config, "aot_patch_structural_updates") ==
         "true") != (profile == "interpreter-structural"))
      return false;
    const auto path = fml::paths::JoinPaths(
        {assets_path, full ? shorebird::kReplacementBaseAsset
                           : shorebird::kInterpreterBaseAsset});
    std::vector<uint8_t> baseline;
    if (!ReadOwnedFile(path, kMaximumInterpreterArtifactBytes, &baseline))
      return false;
    std::lock_guard<std::mutex> lock(baseline_mutex);
    const std::string identity(bytes.begin(), bytes.end());
    if (baseline_bytes &&
        (baseline_identity != identity || *baseline_bytes != baseline))
      return false;
    baseline_identity = identity;
    baseline_bytes =
        std::make_shared<const std::vector<uint8_t>>(std::move(baseline));
    config.release_baseline_callbacks = {
        OpenReleaseBaseline, ReadReleaseBaseline, SeekReleaseBaseline,
        CloseReleaseBaseline};
  }
  config.release_scope_json.assign(bytes.begin(), bytes.end());
  return true;
}

std::shared_ptr<const shorebird::InterpreterReplacementBaseConfig>
LoadInterpreterReplacementBaseConfig(const std::string& yaml,
                                     const std::string& assets_path) {
  auto key_count = [&](const std::string& key) {
    std::stringstream input(yaml);
    std::string line;
    const auto prefix = key + ":";
    size_t count = 0;
    while (std::getline(input, line)) {
      count += line.compare(0, prefix.size(), prefix) == 0;
    }
    return count;
  };
  const auto profile = GetValueFromYaml(yaml, "aot_patch_full_replacement");
  const auto profile_keys = key_count("aot_patch_full_replacement");
  if (profile_keys == 0 || (profile_keys == 1 && profile == "false")) {
    return nullptr;
  }
  auto base = std::make_shared<shorebird::InterpreterReplacementBaseConfig>();
  auto valid_hash = [](const std::string& hash) {
    return hash.size() == 64 &&
           hash.find_first_not_of("0123456789abcdef") == std::string::npos;
  };
  base->host_abi = GetValueFromYaml(yaml, "aot_patch_host_abi");
  base->snapshot_hash = GetValueFromYaml(yaml, "aot_patch_base_snapshot_hash");
  const auto structural =
      GetValueFromYaml(yaml, "aot_patch_structural_updates");
  if (profile != "true" || profile_keys != 1 || assets_path.empty() ||
      key_count("aot_patch_runtime_mode") != 1 ||
      key_count("aot_patch_replacement_base") != 1 ||
      key_count("aot_patch_host_abi") != 1 ||
      key_count("aot_patch_base_snapshot_hash") != 1 ||
      key_count("aot_patch_structural_updates") > 1 ||
      GetValueFromYaml(yaml, "aot_patch_runtime_mode") !=
          "dart-bytecode-interpreter" ||
      (key_count("aot_patch_structural_updates") == 1 &&
       structural != "false") ||
      GetValueFromYaml(yaml, "aot_patch_replacement_base") !=
          shorebird::kReplacementBaseAsset ||
      !valid_hash(base->host_abi) || !valid_hash(base->snapshot_hash)) {
    base->validation_error = "Invalid compiled full replacement configuration";
    return base;
  }
  // Never take a path from YAML. The one fixed asset is inside the signed
  // flutter_assets root, independent of updater storage and code cache paths.
  base->path =
      fml::paths::JoinPaths({assets_path, shorebird::kReplacementBaseAsset});
  return base;
}

std::shared_ptr<const shorebird::InterpreterPatchConfig>
CreateInterpreterPatchConfig(
    const std::string& yaml,
    const std::string& release_version,
    const std::string& active_path,
    const shorebird::InterpreterReplacementBaseConfig* base,
    shorebird::InterpreterPatchTarget target) {
  if (active_path.empty()) {
    return nullptr;
  }
  auto patch = std::make_shared<shorebird::InterpreterPatchConfig>();
  patch->path = active_path;
  patch->target = target;
  patch->full_replacement = base != nullptr;
  if (base) {
    patch->host_abi = base->host_abi;
  }
  patch->app_id = GetValueFromYaml(yaml, "app_id");
  patch->app_build_id = GetValueFromYaml(yaml, "aot_patch_app_build_id");
  if (patch->app_build_id.empty()) {
    patch->app_build_id = release_version;
  }
  patch->base_flavor_id = GetValueFromYaml(yaml, "aot_patch_base_flavor_id");
  patch->base_license_type =
      GetValueFromYaml(yaml, "aot_patch_base_license_type");
  patch->flavor_id = GetValueFromYaml(yaml, "aot_patch_flavor_id");
  patch->license_type = GetValueFromYaml(yaml, "aot_patch_license_type");
  patch->sdk_hash = GetValueFromYaml(yaml, "aot_patch_sdk_hash");
  patch->base_snapshot_hash =
      GetValueFromYaml(yaml, "aot_patch_base_snapshot_hash");
  patch->obfuscation_map_hash =
      GetValueFromYaml(yaml, "aot_patch_obfuscation_map_hash");
  patch->key_id = GetValueFromYaml(yaml, "aot_patch_key_id");
  patch->strict_verification =
      GetValueFromYaml(yaml, "aot_patch_runtime_mode") ==
          "dart-bytecode-interpreter" &&
      GetValueFromYaml(yaml, "patch_response_verification") == "required" &&
      GetValueFromYaml(yaml, "patch_verification") == "strict" &&
      !GetValueFromYaml(yaml, "patch_public_key").empty() &&
      GetValueFromYaml(yaml, "aot_patch_key_hex").empty();
  return patch;
}

}  // namespace flutter
