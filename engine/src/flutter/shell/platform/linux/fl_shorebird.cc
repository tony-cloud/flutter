#include "flutter/shell/platform/linux/fl_shorebird.h"

#include <fstream>
#include <sstream>
#include <string>

#include "flutter/fml/file.h"
#include "flutter/fml/logging.h"
#include "flutter/fml/paths.h"
#include "flutter/shell/common/shorebird/shorebird.h"
#include "rapidjson/document.h"
#include "third_party/tonic/filesystem/filesystem/file.h"

// Namespaced to avoid Google style warnings.
namespace flutter {

gboolean SetUpShorebird(const char* assets_path,
                        const char* original_aot_path,
                        std::string& patch_path) {
  auto shorebird_yaml_path =
      fml::paths::JoinPaths({assets_path, "shorebird.yaml"});
  std::string shorebird_yaml_contents("");
  if (!filesystem::ReadFileToString(shorebird_yaml_path,
                                    &shorebird_yaml_contents)) {
    FML_LOG(ERROR) << "Failed to read shorebird.yaml.";
    return false;
  }

  RequireSelectionV2IfMarked(shorebird_yaml_contents);
  if (!original_aot_path || !*original_aot_path)
    return false;
  std::string code_cache_path =
      fml::paths::JoinPaths({g_get_home_dir(), ".shorebird_cache"});
  auto version_json_path = fml::paths::JoinPaths({assets_path, "version.json"});
  std::ifstream input(version_json_path);
  if (!input) {
    return false;
  }
  std::string json_contents{std::istreambuf_iterator<char>(input),
                            std::istreambuf_iterator<char>()};

  rapidjson::Document json_doc;
  json_doc.Parse(json_contents.c_str());
  if (json_doc.HasParseError()) {
    // Could not parse version file, aborting.
    return false;
  }

  if (!json_doc.IsObject() || !json_doc.HasMember("version") ||
      !json_doc["version"].IsString() || !json_doc.HasMember("build_number") ||
      !json_doc["build_number"].IsString())
    return false;
  const auto version_map = json_doc.GetObject();
  ReleaseVersion release_version{version_map["version"].GetString(),
                                 version_map["build_number"].GetString()};

  ShorebirdConfigArgs shorebird_args(code_cache_path, code_cache_path,
                                     original_aot_path, shorebird_yaml_contents,
                                     release_version);
  shorebird_args.assets_path = assets_path;
  return ConfigureShorebird(shorebird_args, patch_path);
}

}  // namespace flutter
