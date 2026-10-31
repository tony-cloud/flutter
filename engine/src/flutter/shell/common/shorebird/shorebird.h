#ifndef FLUTTER_SHELL_COMMON_SHOREBIRD_SHOREBIRD_H_
#define FLUTTER_SHELL_COMMON_SHOREBIRD_SHOREBIRD_H_

#include <cstdint>
#include <functional>
#include <memory>
#include <string>

#include "flutter/common/settings.h"
#include "flutter/fml/memory/ref_ptr.h"
#include "shell/platform/embedder/embedder.h"

namespace flutter {

class DartSnapshot;

// Release-owned resource policy, independent of unsigned patch metadata. The
// current measured fixtures top out at 13,336,480 bytes (~40x below this
// budget); they do not represent every application. Larger releases can
// override this in compiled shorebird.yaml using native_patch_max_bytes.
constexpr uint64_t kDefaultNativePatchMaxBytes = 512ULL * 1024 * 1024;
bool ResolveNativePatchMaxBytes(const std::string& compiled_yaml,
                                uint64_t explicit_max_bytes,
                                uint64_t& max_bytes);

/// Version and build number of the release.
/// Used by ShorebirdConfigArgs.
struct ReleaseVersion {
  std::string version;
  std::string build_number;
};

/// Arguments for ConfigureShorebird.
/// Used by Desktop implementations.
struct ShorebirdConfigArgs {
  std::string code_cache_path;
  std::string app_storage_path;
  std::string release_app_library_path;
  std::string shorebird_yaml;
  ReleaseVersion release_version;
  uint64_t max_native_image_bytes = 0;

  ShorebirdConfigArgs(std::string code_cache_path,
                      std::string app_storage_path,
                      std::string release_app_library_path,
                      std::string shorebird_yaml,
                      ReleaseVersion release_version)
      : code_cache_path(code_cache_path),
        app_storage_path(app_storage_path),
        release_app_library_path(release_app_library_path),
        shorebird_yaml(shorebird_yaml),
        release_version(release_version) {}
};

/// Newer api, used by Desktop implementations.
/// Does not directly manipulate Settings.
/// Sets |patch_path| to the patch to boot, or clears it when there is none.
/// Load it with LoadPatchOrBase.
bool ConfigureShorebird(const ShorebirdConfigArgs& args,
                        std::string& patch_path);

/// Loads the AOT code for this boot with |load|, which returns whether it
/// loaded the library at the path it is given. Tries |patch_path| first,
/// unless it is empty. If the patch does not load, reports the launch as
/// failed, so the updater marks the patch bad and sends a failure event, and
/// loads |base_path|, the release's own code, instead. Returns whether the
/// last load succeeded. Used by the desktop embedders, which load the AOT
/// library themselves before any Shell exists.
bool LoadPatchOrBase(const std::string& patch_path,
                     const std::string& base_path,
                     const std::function<bool(const std::string&)>& load);

/// Older api used by iOS and Android, directly manipulates Settings.
void ConfigureShorebird(std::string code_cache_path,
                        std::string app_storage_path,
                        Settings& settings,
                        const std::string& shorebird_yaml,
                        const std::string& version,
                        const std::string& version_code,
                        uint64_t max_native_image_bytes = 0);

// Parse the signed compiled profile before updater initialization. Retain an
// invalid full-profile config so runtime startup fails closed. Absent/false is
// the legacy profile and returns nullptr. Exposed for focused config tests.
std::shared_ptr<const shorebird::InterpreterReplacementBaseConfig>
LoadInterpreterReplacementBaseConfig(const std::string& yaml,
                                     const std::string& assets_path);

/// Used for reading app_id from shorebird.yaml.
/// Exposed for testing.
std::string GetValueFromYaml(const std::string& yaml, const std::string& key);

}  // namespace flutter

#endif  // FLUTTER_SHELL_COMMON_SHOREBIRD_SHOREBIRD_H_
