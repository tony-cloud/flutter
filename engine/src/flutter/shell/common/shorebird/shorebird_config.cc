// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/shell/common/shorebird/shorebird.h"

#include <cstring>
#include <sstream>

#include "flutter/fml/paths.h"
#include "flutter/runtime/shorebird/interpreter_patch.h"
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

}  // namespace flutter
