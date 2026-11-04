
#include "flutter/shell/common/shorebird/shorebird.h"

#include <cstddef>
#include <memory>
#include <optional>
#include <utility>
#include <vector>

#include "flutter/fml/command_line.h"
#include "flutter/fml/file.h"
#include "flutter/fml/macros.h"
#include "flutter/fml/mapping.h"
#include "flutter/fml/message_loop.h"
#include "flutter/fml/native_library.h"
#include "flutter/fml/paths.h"
#include "flutter/lib/ui/plugins/callback_cache.h"
#include "flutter/runtime/dart_snapshot.h"
#include "flutter/runtime/dart_vm.h"
#include "flutter/runtime/shorebird/interpreter_patch.h"
#include "flutter/shell/common/shell.h"
#include "flutter/shell/common/shorebird/snapshots_data_handle.h"
#include "flutter/shell/common/shorebird/updater.h"
#include "flutter/shell/common/switches.h"
#include "fml/logging.h"
#include "shell/platform/embedder/embedder.h"
#include "third_party/dart/runtime/include/dart_native_api.h"

// Namespaced to avoid Google style warnings.
namespace flutter {

// Old Android versions (e.g. the v16 ndk Flutter uses) don't always include a
// getauxval symbol, but the Rust ring crate assumes it exists:
// https://github.com/briansmith/ring/blob/fa25bf3a7403c9fe6458cb87bd8427be41225ca2/src/cpu/arm.rs#L22
// It uses it to determine if the CPU supports AES instructions.
// Making this a weak symbol allows the linker to use a real version instead
// if it can find one.
// BoringSSL just reads from procfs instead, which is what we would do if
// we needed to implement this ourselves.  Implementation looks straightforward:
// https://lwn.net/Articles/519085/
// https://github.com/google/boringssl/blob/6ab4f0ae7f2db96d240eb61a5a8b4724e5a09b2f/crypto/cpu_arm_linux.c
#if defined(__ANDROID__) && defined(__arm__)
extern "C" __attribute__((weak)) unsigned long getauxval(unsigned long type) {
  return 0;
}
#endif

// Global reference to the base (unpatched) snapshot from the App.framework,
// set on iOS and macOS. Patches there are diffed against just the Dart
// snapshot regions of the app binary, which FileCallbacksImpl serves to the
// updater from this snapshot. It is process-global because:
// 1. The Shorebird updater library is a process-global singleton with its own
//    internal state.
// 2. The base snapshot is immutable (baked into the app) so sharing it across
//    isolate groups is safe.
//
// Note: This design doesn't support multiple engines with different base
// snapshots, but I'm not aware of any use cases for that.
static fml::RefPtr<const DartSnapshot> vm_snapshot;

#if SHOREBIRD_USE_INTERPRETER
void SetBaseSnapshot(Settings& settings) {
  // The VM resolve path is patch-blind and does not report a launch before a
  // Shell exists. VM and isolate symbols now refer to the same data/text pair.
  vm_snapshot = DartSnapshot::VMSnapshotFromSettings(settings);
  if (!vm_snapshot) {
    FML_LOG(ERROR) << "Shorebird updater: failed to resolve base snapshot";
    return;
  }

  const intptr_t data_size =
      Dart_SnapshotDataSize(vm_snapshot->GetDataMapping());
  const intptr_t instructions_size =
      Dart_SnapshotInstrSize(vm_snapshot->GetInstructionsMapping());
  FML_LOG(INFO) << "[shorebird] SetBaseSnapshot mappings: data_size="
                << data_size << " instructions_size=" << instructions_size
                << " total=" << (data_size + instructions_size);

  // The open Dart interpreter installs bytecode through its public patch API;
  // retain the base mappings here only for the updater file callback stream.
}
#endif  // SHOREBIRD_USE_INTERPRETER

class FileCallbacksImpl {
 public:
  static void* Open();
  static uintptr_t Read(void* file, uint8_t* buffer, uintptr_t length);
  static int64_t Seek(void* file, int64_t offset, int32_t whence);
  static void Close(void* file);
};

shorebird::FileCallbacks ShorebirdFileCallbacks() {
  return {
      .open = FileCallbacksImpl::Open,
      .read = FileCallbacksImpl::Read,
      .seek = FileCallbacksImpl::Seek,
      .close = FileCallbacksImpl::Close,
  };
}

namespace {
std::string HostPlatform() {
#if FML_OS_IOS
  return "ios";
#elif FML_OS_MACOSX
  return "macos";
#elif FML_OS_ANDROID
  return "android";
#elif FML_OS_WIN
  return "windows";
#else
  return "linux";
#endif
}
std::optional<shorebird::InterpreterPatchTarget> MacInterpreterTarget() {
#if FML_ARCH_CPU_ARM64
  return shorebird::InterpreterPatchTarget::kMacOSArm64;
#elif FML_ARCH_CPU_X86_64
  return shorebird::InterpreterPatchTarget::kMacOSX64;
#else
  return std::nullopt;
#endif
}
void SelectPreparedInterpreterPatch(const std::string& yaml,
                                    const std::string& version,
                                    Settings& settings,
                                    shorebird::InterpreterPatchTarget target) {
  auto& updater = shorebird::Updater::Instance();
  settings.shorebird_interpreter_begin_base = [] {
    auto& updater = shorebird::Updater::Instance();
    auto source = updater.PrepareBootSource();
    return source &&
           source->kind() == shorebird::PreparedBootSource::Kind::kBase &&
           updater.BeginBootSource(source->selection_id());
  };
  auto source = updater.PrepareBootSource();
  std::shared_ptr<const shorebird::InterpreterPatchConfig> candidate;
  if (source && source->kind() == shorebird::PreparedBootSource::Kind::kPath) {
    auto parsed = CreateInterpreterPatchConfig(
        yaml, version, source->path(),
        settings.shorebird_interpreter_replacement_base.get(), target);
    if (parsed) {
      auto patch = std::make_shared<shorebird::InterpreterPatchConfig>(*parsed);
      patch->selection_protocol_v2 = true;
      patch->release_version = version;
      patch->runtime_profile =
          patch->full_replacement ? "interpreter-full"
          : GetValueFromYaml(yaml, "aot_patch_structural_updates") == "true"
              ? "interpreter-structural"
              : "interpreter-body";
      patch->verified_selection_json = source->verified_selection_json();
      patch->selection_id = source->selection_id();
      patch->patch_number = source->patch_number();
      patch->owned_artifact =
          shorebird::LoadOwnedInterpreterArtifact(source->path());
      patch->owned_artifact_read_failed = !patch->owned_artifact;
      patch->begin_boot_source = [id = source->selection_id()] {
        return shorebird::Updater::Instance().BeginBootSource(id);
      };
      candidate = std::move(patch);
    }
  }
  settings.shorebird_interpreter_patch =
      shorebird::SelectInterpreterPatchForProcess(std::move(candidate));
}
}  // namespace

/// Newer api, used by Desktop implementations.
/// Does not directly manipulate Settings.
// TODO(eseidel): Consolidate this with the other ConfigureShorebird() API.
bool ConfigureShorebird(const ShorebirdConfigArgs& args,
                        std::string& patch_path) {
  patch_path.clear();
  RequireSelectionV2IfMarked(args.shorebird_yaml);
  auto shorebird_updater_dir_name = "shorebird_updater";

  // Parse app id from shorebird.yaml
  std::string app_id = GetValueFromYaml(args.shorebird_yaml, "app_id");
  if (app_id.empty()) {
    FML_LOG(ERROR) << "Shorebird updater: appid not found in shorebird.yaml";
    return false;
  }

  auto code_cache_dir = fml::paths::JoinPaths(
      {std::move(args.code_cache_path), shorebird_updater_dir_name, app_id});
  auto app_storage_dir = fml::paths::JoinPaths(
      {std::move(args.app_storage_path), shorebird_updater_dir_name, app_id});

  fml::CreateDirectory(fml::paths::GetCachesDirectory(),
                       {shorebird_updater_dir_name},
                       fml::FilePermission::kReadWrite);

  // Combine version and version_code into a single string.
  // We could also pass these separately through to the updater if needed.
  auto release_version = args.release_version.version;
  if (!args.release_version.build_number.empty()) {
    release_version += "+" + args.release_version.build_number;
  }

  shorebird::AppConfig config;
  config.release_version = release_version;
  config.original_libapp_paths = {args.release_app_library_path};
  config.app_storage_dir = app_storage_dir;
  config.code_cache_dir = code_cache_dir;
  config.file_callbacks = ShorebirdFileCallbacks();
  config.yaml_config = args.shorebird_yaml;
  config.max_native_image_bytes = args.max_native_image_bytes;
  if (!ConfigureSelectionV2(config, args.assets_path, HostPlatform(),
                            ShorebirdHostArch())) {
    return false;
  }
#if FML_OS_LINUX || FML_OS_WIN
  if (shorebird::Updater::Instance().SupportsPreparedBootSources() &&
      DartVM::IsRunningPrecompiledCode()) {
    shorebird::Updater::Instance().RequirePreparedBootSource();
    if (!ResolveNativePatchMaxBytes(args.shorebird_yaml,
                                    args.max_native_image_bytes,
                                    config.max_native_image_bytes)) {
      FML_LOG(ERROR) << "Invalid native_patch_max_bytes release configuration";
      return false;
    }
  }
#endif

  // The open CLI diffs desktop patches against the complete release library.
  // Leave the snapshot callback unopened so the updater reads that same file.
  // Snapshot-region macOS diffs require a matching public CLI extractor before
  // both ends of this contract can change together.

  bool init_result = shorebird::Updater::Instance().Init(config);

  if (config.max_native_image_bytes != 0 || config.selection_protocol_v2) {
    // Selection occurs at the actual loader. In particular, do not ask the
    // legacy path validator to interpret encrypted persistent state.
    return init_result;
  }

  FML_LOG(INFO) << "Checking for active patch";
  shorebird::Updater::Instance().ValidateNextBootPatch();
  std::string active_path = shorebird::Updater::Instance().NextBootPatchPath();
  if (!active_path.empty()) {
    patch_path = active_path;
    FML_LOG(INFO) << "Shorebird updater: patch path: " << patch_path;
  } else {
    FML_LOG(INFO) << "Shorebird updater: no active patch.";
  }

  // Launch reporting does not happen here. ResolveIsolateData in
  // runtime/dart_snapshot.cc reports the start, so a FlutterEngineGroup or
  // add-to-app host that calls ConfigureShorebird() without ever creating a
  // Shell does not record a boot that never happened. The update thread
  // starts from the Shell's launch-success report, after the boot is
  // recorded; see the Updater class comment.
  return init_result;
}

bool ConfigureShorebirdInterpreter(const ShorebirdConfigArgs& args,
                                   Settings& settings) {
  shorebird::SealInterpreterKeyProvider();
  const auto target = MacInterpreterTarget();
  if (!target) {
    FML_LOG(ERROR) << "Unsupported signed interpreter host architecture";
    return false;
  }
  settings.shorebird_interpreter_replacement_base =
      LoadInterpreterReplacementBaseConfig(args.shorebird_yaml,
                                           settings.assets_path);
  const auto& base = settings.shorebird_interpreter_replacement_base;
  if (!base || !base->validation_error.empty()) {
    // Retain an invalid profile in Settings as well as rejecting this startup.
    // An inactive native app must never be used as an implicit fallback.
    return false;
  }
  std::string active_path;
  auto interpreter_args = args;
  interpreter_args.assets_path = settings.assets_path;
  const bool initialized = ConfigureShorebird(interpreter_args, active_path);
  if (!initialized) {
    if (shorebird::Updater::Instance().RequiresSelectionV2()) {
      FML_LOG(ERROR) << "Invalid compiled v2 scope or checked updater "
                        "initialization failed";
      return false;
    }
    active_path.clear();
  }
  auto version = args.release_version.version;
  if (!args.release_version.build_number.empty()) {
    version += "+" + args.release_version.build_number;
  }
  if (GetValueFromYaml(args.shorebird_yaml, "selection_protocol") == "2") {
    if (initialized) {
      SelectPreparedInterpreterPatch(args.shorebird_yaml, version, settings,
                                     *target);
    } else {
      settings.shorebird_interpreter_patch =
          shorebird::SelectInterpreterPatchForProcess(nullptr);
    }
    return true;
  }
  settings.shorebird_interpreter_patch =
      shorebird::SelectInterpreterPatchForProcess(CreateInterpreterPatchConfig(
          args.shorebird_yaml, version, active_path, base.get(), *target));
  return true;
}

bool LoadPatchOrBase(const std::string& patch_path,
                     const std::string& base_path,
                     const std::function<bool(const std::string&)>& load) {
  if (patch_path.empty()) {
    return load(base_path);
  }
  if (load(patch_path)) {
    return true;
  }
  FML_LOG(ERROR) << "Shorebird: patch load failed, running base code from "
                 << base_path << " instead of " << patch_path;
  // The failure report marks the booting patch bad, and a patch is only
  // booting once the start is reported. Both are guarded once per process,
  // so the Shell's own start report (ResolveIsolateData) is a no-op, and its
  // success report does not record the base-code boot as the patch's. This
  // is the same sequence TryLoadFromPatch runs on iOS.
  shorebird::Updater::Instance().ReportLaunchStart();
  shorebird::Updater::Instance().ReportLaunchFailure();
  return load(base_path);
}

/// Older api used by iOS and Android, directly manipulates Settings.
// TODO(eseidel): Consolidate this with the other ConfigureShorebird() API.
void ConfigureShorebird(std::string code_cache_path,
                        std::string app_storage_path,
                        Settings& settings,
                        const std::string& shorebird_yaml,
                        const std::string& version,
                        const std::string& version_code,
                        uint64_t max_native_image_bytes,
                        const std::string* compiled_scope_json) {
  const bool requires_v2 = RequireSelectionV2IfMarked(shorebird_yaml);
#if FML_OS_ANDROID
  if (requires_v2 && !ValidateAndroidNativeReleaseLibraryPaths(
                         settings.application_library_paths)) {
    FML_LOG(ERROR) << "V2 requires the unambiguous packaged original libapp.so";
    return;
  }
#endif
  // If you are crashing here, you probably are running Shorebird in a Debug
  // config, where the AOT snapshot won't be linked into the process, and thus
  // lookups will fail.  Change your Scheme to Release to fix:
  // https://github.com/flutter/flutter/wiki/Debugging-the-engine#debugging-ios-builds-with-xcode
  if (!requires_v2) {
    FML_CHECK(DartSnapshot::VMSnapshotFromSettings(settings))
        << "XCode Scheme must be set to Release to use Shorebird";
  }

  auto shorebird_updater_dir_name = "shorebird_updater";

  auto code_cache_dir = fml::paths::JoinPaths(
      {std::move(code_cache_path), shorebird_updater_dir_name});
  auto app_storage_dir = fml::paths::JoinPaths(
      {std::move(app_storage_path), shorebird_updater_dir_name});

  fml::CreateDirectory(fml::paths::GetCachesDirectory(),
                       {shorebird_updater_dir_name},
                       fml::FilePermission::kReadWrite);

  // Combine version and version_code into a single string.
  // We could also pass these separately through to the updater if needed.
  shorebird::AppConfig config;
  config.release_version = version + "+" + version_code;
  config.original_libapp_paths = settings.application_library_paths;
  config.app_storage_dir = app_storage_dir;
  config.code_cache_dir = code_cache_dir;
  config.file_callbacks = ShorebirdFileCallbacks();
  config.yaml_config = shorebird_yaml;
  config.max_native_image_bytes = max_native_image_bytes;
  auto reject_v2_configuration = [&settings] {
    auto invalid =
        std::make_shared<shorebird::InterpreterReplacementBaseConfig>();
    invalid->validation_error =
        "Invalid compiled v2 scope or checked updater initialization failed";
    settings.shorebird_interpreter_replacement_base = std::move(invalid);
    settings.shorebird_interpreter_patch =
        shorebird::SelectInterpreterPatchForProcess(nullptr);
    FML_LOG(ERROR)
        << "Invalid compiled v2 scope or checked updater initialization failed";
  };
  if (!ConfigureSelectionV2(config, settings.assets_path, HostPlatform(),
                            ShorebirdHostArch(), compiled_scope_json)) {
    reject_v2_configuration();
    return;
  }
#if FML_OS_ANDROID && !SHOREBIRD_USE_INTERPRETER
  if (shorebird::Updater::Instance().SupportsPreparedBootSources() &&
      DartVM::IsRunningPrecompiledCode()) {
    shorebird::Updater::Instance().RequirePreparedBootSource();
    if (!ResolveNativePatchMaxBytes(shorebird_yaml, max_native_image_bytes,
                                    config.max_native_image_bytes)) {
      FML_LOG(ERROR) << "Invalid native_patch_max_bytes release configuration";
      return;
    }
  }
#endif

#if FML_OS_IOS
  shorebird::SealInterpreterKeyProvider();
  settings.shorebird_interpreter_replacement_base =
      LoadInterpreterReplacementBaseConfig(shorebird_yaml,
                                           settings.assets_path);
#endif
  if (requires_v2) {
    FML_CHECK(DartSnapshot::VMSnapshotFromSettings(settings))
        << "XCode Scheme must be set to Release to use Shorebird";
  }
  if (!shorebird::Updater::Instance().Init(config)) {
    FML_LOG(ERROR) << "Shorebird updater initialization failed";
    if (shorebird::Updater::Instance().RequiresSelectionV2()) {
      reject_v2_configuration();
      return;
    }
#if FML_OS_IOS
    settings.shorebird_interpreter_patch =
        shorebird::SelectInterpreterPatchForProcess(nullptr);
#else
    settings.shorebird_interpreter_patch.reset();
#endif
    return;
  }

  // We only set the base snapshot on iOS for now.
#if SHOREBIRD_USE_INTERPRETER
  SetBaseSnapshot(settings);
#endif

  if (shorebird::Updater::Instance().UsesPreparedBootSource()) {
#if FML_OS_IOS
    if (config.selection_protocol_v2) {
      SelectPreparedInterpreterPatch(
          shorebird_yaml, config.release_version, settings,
          shorebird::InterpreterPatchTarget::kIOSArm64);
    }
#endif
    // Preserve release paths for BASE; the actual loader begins the source.
    return;
  }
  shorebird::Updater::Instance().ValidateNextBootPatch();
  std::string active_path = shorebird::Updater::Instance().NextBootPatchPath();
  if (!active_path.empty()) {
    FML_LOG(INFO) << "Shorebird updater: active path: " << active_path;

#if FML_OS_IOS && SHOREBIRD_MIXED_MODE
    // A linked AOT patch (vmcode v1). The updater has verified its signed hash
    // over the whole file and its header against this release; the engine
    // checks the release text hash again against the mapped release and runs
    // the release if the patch does not load or link (runtime/shorebird/
    // mixed_patch.h).
    const std::string kVmcodeSuffix = ".vmcode";
    if (active_path.size() > kVmcodeSuffix.size() &&
        active_path.compare(active_path.size() - kVmcodeSuffix.size(),
                            kVmcodeSuffix.size(), kVmcodeSuffix) == 0) {
      settings.shorebird_mixed_patch_path = active_path;
      settings.shorebird_interpreter_patch =
          shorebird::SelectInterpreterPatchForProcess(nullptr);
      return;
    }
#endif
#if FML_OS_IOS
    // An encrypted artifact is JSON/bytecode data, never a native image. Keep
    // the reviewed base snapshot linked and install only before its main runs.
    settings.shorebird_interpreter_patch =
        shorebird::SelectInterpreterPatchForProcess(
            CreateInterpreterPatchConfig(
                shorebird_yaml, config.release_version, active_path,
                settings.shorebird_interpreter_replacement_base.get(),
                shorebird::InterpreterPatchTarget::kIOSArm64));
#elif SHOREBIRD_USE_INTERPRETER
    // Front-insert rather than clear. A linked patch carries only the code it
    // rewrote, and everything it linked against still executes out of the base
    // image, so the base has to stay resolvable for the life of the process.
    // SearchMapping takes the first path that resolves a symbol, so the patch
    // still wins the lookup without evicting the base.
    settings.application_library_paths.insert(
        settings.application_library_paths.begin(), active_path);
#else
    settings.application_library_paths.clear();
    settings.application_library_paths.emplace_back(active_path);
#endif
  } else {
    FML_LOG(INFO) << "Shorebird updater: no active patch.";
#if FML_OS_IOS
    settings.shorebird_interpreter_patch =
        shorebird::SelectInterpreterPatchForProcess(nullptr);
#endif
  }

  // Launch reporting does not happen here. ResolveIsolateData in
  // runtime/dart_snapshot.cc reports the start, so a FlutterEngineGroup or
  // add-to-app host that calls ConfigureShorebird() without ever creating a
  // Shell does not record a boot that never happened. The update thread
  // starts from the Shell's launch-success report, after the boot is
  // recorded; see the Updater class comment.
}

void* FileCallbacksImpl::Open() {
  // Only iOS sets a base snapshot. Its patches are generated from
  // just the Dart parts of the snapshot, excluding the Mach-O headers and code
  // signature, which change on every build and whenever the app is re-signed.
  if (!vm_snapshot) {
    return nullptr;
  }
  // vm_snapshot, not isolate_snapshot: both resolve the same symbol now, but
  // only the VM path is patch-blind, and this stream must be the unpatched
  // base.
  return SnapshotsDataHandle::createForSnapshots(*vm_snapshot).release();
}

uintptr_t FileCallbacksImpl::Read(void* file,
                                  uint8_t* buffer,
                                  uintptr_t length) {
  return reinterpret_cast<SnapshotsDataHandle*>(file)->Read(buffer, length);
}

int64_t FileCallbacksImpl::Seek(void* file, int64_t offset, int32_t whence) {
  // Currently we only support blob handles.
  return reinterpret_cast<SnapshotsDataHandle*>(file)->Seek(offset, whence);
}

void FileCallbacksImpl::Close(void* file) {
  delete reinterpret_cast<SnapshotsDataHandle*>(file);
}

}  // namespace flutter
