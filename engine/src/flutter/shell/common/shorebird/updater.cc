// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/common/shorebird/updater.h"

#include <utility>

#include "flutter/fml/build_config.h"
#include "flutter/fml/logging.h"

#if !FML_OS_WIN
#include <unistd.h>
#endif

#if SHOREBIRD_PLATFORM_SUPPORTED
#include "third_party/updater/library/include/updater_engine.h"
#endif

namespace flutter {
namespace shorebird {

PreparedBootSource::PreparedBootSource(Kind kind,
                                       uint64_t selection_id,
                                       uint64_t patch_number,
                                       uint64_t image_size,
                                       int fd,
                                       std::string path,
                                       std::shared_ptr<const uint8_t> memory)
    : kind_(kind),
      selection_id_(selection_id),
      patch_number_(patch_number),
      image_size_(image_size),
      fd_(fd),
      path_(std::move(path)),
      memory_(std::move(memory)) {}

PreparedBootSource::~PreparedBootSource() {
#if !FML_OS_WIN
  if (fd_ >= 0) {
    close(fd_);
  }
#endif
}

int PreparedBootSource::TakeFD() {
  int fd = fd_;
  fd_ = -1;
  return fd;
}

// Static member definitions
std::unique_ptr<Updater> Updater::instance_;
std::mutex Updater::instance_mutex_;
std::mutex Updater::prepared_load_mutex_;
std::atomic<uint64_t> Updater::loaded_selection_id_{0};
std::atomic<bool> Updater::prepared_sources_{false};
std::atomic<bool> Updater::prepared_configuration_failed_{false};
std::atomic<bool> Updater::prepared_recovery_failed_{false};
std::atomic<bool> Updater::launch_started_{false};
std::atomic<bool> Updater::launch_completed_{false};
std::atomic<bool> Updater::initialized_{false};
std::atomic<bool> Updater::update_thread_started_{false};

Updater& Updater::Instance() {
  std::lock_guard<std::mutex> lock(instance_mutex_);
  if (!instance_) {
#if SHOREBIRD_PLATFORM_SUPPORTED
    instance_ = std::make_unique<RealUpdater>();
#else
    instance_ = std::make_unique<NoOpUpdater>();
#endif
  }
  return *instance_;
}

void Updater::SetInstanceForTesting(std::unique_ptr<Updater> instance) {
  std::lock_guard<std::mutex> lock(instance_mutex_);
  instance_ = std::move(instance);
}

void Updater::ResetInstanceForTesting() {
  std::lock_guard<std::mutex> lock(instance_mutex_);
  instance_.reset();
}

void Updater::ResetLaunchStateForTesting() {
  loaded_selection_id_.store(0);
  prepared_sources_.store(false);
  prepared_configuration_failed_.store(false);
  prepared_recovery_failed_.store(false);
  launch_started_.store(false);
  launch_completed_.store(false);
  initialized_.store(false);
  update_thread_started_.store(false);
}

bool Updater::Init(const AppConfig& config) {
  if (config.max_native_image_bytes != 0) {
    RequirePreparedBootSource();
  }
  bool result = DoInit(config);
  // Latch rather than assign: add-to-app calls Init once per engine, and a
  // later failure must not forget that the process already configured.
  if (result) {
    initialized_.store(true);
    if (config.max_native_image_bytes != 0) {
      prepared_configuration_failed_.store(false);
    }
  }
  return result;
}

void Updater::RequirePreparedBootSource() {
  prepared_sources_.store(true);
  prepared_configuration_failed_.store(true);
}

bool Updater::UsesPreparedBootSource() const {
  return prepared_sources_.load();
}

std::unique_ptr<PreparedBootSource> Updater::PrepareBootSource() {
  return nullptr;
}

bool Updater::BeginBootSource(uint64_t selection_id) {
  if (!DoBeginBootSource(selection_id)) {
    return false;
  }
  launch_started_.store(true);
  return true;
}

bool Updater::AbortBootSource(uint64_t selection_id) {
  if (DoAbortBootSource(selection_id)) {
    return true;
  }
  // Failed bookkeeping must not turn the subsequent base boot into a success
  // report for a candidate whose breadcrumb could not be cleared.
  launch_completed_.store(true);
  prepared_recovery_failed_.store(true);
  return false;
}

bool Updater::LoadPreparedBootSource(
    const std::function<bool(PreparedBootSource&)>& load_patch,
    const std::function<bool()>& load_base) {
  if (prepared_configuration_failed_.load()) {
    return false;
  }
  if (prepared_recovery_failed_.load()) {
    // Retain the unresolved breadcrumb for crash recovery. A later engine
    // must not try the candidate again in this process.
    return loaded_selection_id_.load() == 0 && load_base();
  }
  auto source = PrepareBootSource();
  if (!source) {
    return false;
  }
  std::unique_lock<std::mutex> lock(prepared_load_mutex_);
  if (prepared_configuration_failed_.load()) {
    return false;
  }
  const auto loaded_id = loaded_selection_id_.load();
  if (loaded_id != 0) {
    // A running process cannot switch images when a later engine fails to
    // consume its frozen PATH/FD. Refuse that engine without aborting the
    // selection or executing bundled instructions alongside the loaded patch.
    return source->kind() != PreparedBootSource::Kind::kBase &&
           source->selection_id() == loaded_id && BeginBootSource(loaded_id) &&
           load_patch(*source);
  }
  if (prepared_recovery_failed_.load()) {
    return load_base();
  }
  if (BeginBootSource(source->selection_id())) {
    if (source->kind() == PreparedBootSource::Kind::kBase) {
      return load_base();
    }
    if (load_patch(*source)) {
      loaded_selection_id_.store(source->selection_id());
      return true;
    }
    if (!AbortBootSource(source->selection_id())) {
      return load_base();
    }
  }
  // A stale token or returned loader failure invalidates the old selection.
  // Never retry it, ask for a different patch, or fall through to legacy APIs.
  lock.unlock();
  source = PrepareBootSource();
  lock.lock();
  return !prepared_configuration_failed_.load() && source &&
         source->kind() == PreparedBootSource::Kind::kBase &&
         BeginBootSource(source->selection_id()) && load_base();
}

void Updater::ReportLaunchStart() {
  if (UsesPreparedBootSource()) {
    // Only the checked loader-bound begin may start this selection.
    return;
  }
  // Guard: only the first engine in a process should promote next_boot →
  // current_boot in the Rust updater. See class-level comment for rationale.
  bool expected = false;
  if (!launch_started_.compare_exchange_strong(expected, true)) {
    return;
  }
  DoReportLaunchStart();
}

void Updater::ReportLaunchSuccess() {
  // Guard: only report success once per process. Subsequent engines reuse
  // the same patch and don't need to re-confirm the boot. A boot already
  // reported as failed keeps that outcome, so the success is not forwarded.
  bool expected = false;
  if (launch_completed_.compare_exchange_strong(expected, true)) {
    DoReportLaunchSuccess();
  }

  // Outside the guard above: a patch that failed to load already claimed it
  // from TryLoadFromPatch, and the base-code boot reaching here is the launch
  // that most needs a replacement patch. See the class comment.
  MaybeStartUpdateThread();
}

void Updater::MaybeStartUpdateThread() {
  // Two paths reach here and they do not share an invariant. After a
  // successful boot the success report has gone to the updater, so an
  // install can no longer retire the patch we booted and the patch check
  // names it. After a failed patch load the failure report claimed the
  // guard in ReportLaunchSuccess, nothing is recorded as booted, and the
  // process is running base code. See the class comment.
  // We do not support synchronous updates on launch;
  // users can implement custom check-for-updates using
  // package:shorebird_code_push.
  // https://github.com/shorebirdtech/shorebird/issues/950
  // Normal for a build that never configured the updater: Android only calls
  // ConfigureShorebird in release mode, and iOS skips it when the bundle has
  // no shorebird.yaml. Also covers an Init that failed.
  // Checked before the guard below so an engine that never configured cannot
  // claim it on behalf of one that did.
  if (prepared_recovery_failed_.load() || !initialized_.load()) {
    FML_LOG(INFO) << "Shorebird updater not configured, not checking for "
                     "updates.";
    return;
  }
  // Guard: one update thread per process, not one per engine.
  bool expected = false;
  if (!update_thread_started_.compare_exchange_strong(expected, true)) {
    return;
  }
  if (ShouldAutoUpdate()) {
    FML_LOG(INFO) << "Starting Shorebird update";
    StartUpdateThread();
  } else {
    FML_LOG(INFO)
        << "Shorebird auto_update disabled, not checking for updates.";
  }
}

void Updater::ReportLaunchFailure() {
  // Guard: only report failure once per process.
  bool expected = false;
  if (!launch_completed_.compare_exchange_strong(expected, true)) {
    return;
  }
  DoReportLaunchFailure();
}

#if SHOREBIRD_PLATFORM_SUPPORTED
// RealUpdater implementation - wraps the Rust C API

bool RealUpdater::SupportsPreparedBootSources() const {
#if FML_OS_LINUX || FML_OS_WIN || (FML_OS_ANDROID && !SHOREBIRD_USE_INTERPRETER)
  return true;
#else
  return false;
#endif
}

bool RealUpdater::DoInit(const AppConfig& config) {
  // Convert paths to C strings
  std::vector<const char*> c_paths;
  c_paths.reserve(config.original_libapp_paths.size());
  for (const auto& path : config.original_libapp_paths) {
    c_paths.push_back(path.c_str());
  }

  AppParameters params;
  params.release_version = config.release_version.c_str();
  params.original_libapp_paths = c_paths.data();
  params.original_libapp_paths_size = static_cast<int>(c_paths.size());
  params.app_storage_dir = config.app_storage_dir.c_str();
  params.code_cache_dir = config.code_cache_dir.c_str();

  // Convert our FileCallbacks to the Rust struct
  ::FileCallbacks rust_callbacks;
  rust_callbacks.open = config.file_callbacks.open;
  rust_callbacks.read = config.file_callbacks.read;
  rust_callbacks.seek = config.file_callbacks.seek;
  rust_callbacks.close = config.file_callbacks.close;

  if (config.max_native_image_bytes != 0) {
#if FML_OS_LINUX || FML_OS_WIN || (FML_OS_ANDROID && !SHOREBIRD_USE_INTERPRETER)
    ShorebirdEngineOptions options = {};
    options.struct_size = sizeof(options);
#if FML_OS_WIN
    options.native_source_capability = 2;  // VERIFIED_MEMORY_V1
#else
    options.native_source_capability = 1;  // SEALED_FD_V1
#endif
    options.max_native_image_bytes = config.max_native_image_bytes;
    return shorebird_init_with_options(&params, rust_callbacks,
                                       config.yaml_config.c_str(), &options);
#else
    FML_LOG(ERROR)
        << "Prepared native sources are unsupported on this platform";
    return false;
#endif
  }
  return shorebird_init(&params, rust_callbacks, config.yaml_config.c_str());
}

std::unique_ptr<PreparedBootSource> RealUpdater::PrepareBootSource() {
  ShorebirdBootSource source = {};
  source.struct_size = sizeof(source);
  source.fd = -1;
  if (!shorebird_prepare_boot_source(&source)) {
    shorebird_release_boot_source(&source);
    return nullptr;
  }
  const bool valid =
      source.selection_id != 0 &&
      ((source.kind == 0 && source.patch_number == 0 && source.fd == -1 &&
        !source.path) ||
       (source.kind == 1 && source.patch_number != 0 && source.fd == -1 &&
        source.path) ||
       (source.kind == 2 && source.patch_number != 0 && source.fd >= 0 &&
        !source.path && source.image_size != 0) ||
       (source.kind == 3 && source.patch_number != 0 && source.fd == -1 &&
        !source.path && source.image_size != 0));
  if (!valid) {
    shorebird_release_boot_source(&source);
    return nullptr;
  }
  std::shared_ptr<const uint8_t> memory;
  if (source.kind == 3) {
    ShorebirdBootMemory lease = {};
    lease.struct_size = sizeof(lease);
    if (!shorebird_acquire_boot_source_memory(source.selection_id, &lease) ||
        !lease.data || !lease.private_owner ||
        lease.length != source.image_size) {
      shorebird_release_boot_source_memory(&lease);
      shorebird_release_boot_source(&source);
      return nullptr;
    }
    memory = std::shared_ptr<const uint8_t>(
        lease.data, [lease](const uint8_t*) mutable {
          shorebird_release_boot_source_memory(&lease);
        });
  }
  auto result = std::make_unique<PreparedBootSource>(
      static_cast<PreparedBootSource::Kind>(source.kind), source.selection_id,
      source.patch_number, source.image_size, source.fd,
      source.path ? source.path : "", std::move(memory));
  source.fd = -1;  // Ownership transferred to the C++ source.
  shorebird_release_boot_source(&source);
  return result;
}

bool RealUpdater::DoBeginBootSource(uint64_t selection_id) {
  return shorebird_begin_boot_source(selection_id);
}

bool RealUpdater::DoAbortBootSource(uint64_t selection_id) {
  return shorebird_abort_boot_source(selection_id, 0);  // RETRYABLE
}

void RealUpdater::ValidateNextBootPatch() {
  shorebird_validate_next_boot_patch();
}

std::string RealUpdater::NextBootPatchPath() {
  char* c_path = shorebird_next_boot_patch_path();
  if (c_path == nullptr) {
    return "";
  }
  std::string path(c_path);
  shorebird_free_string(c_path);
  return path;
}

void RealUpdater::DoReportLaunchStart() {
  shorebird_report_launch_start();
}

void RealUpdater::DoReportLaunchSuccess() {
  shorebird_report_launch_success();
}

void RealUpdater::DoReportLaunchFailure() {
  shorebird_report_launch_failure();
}

bool RealUpdater::ShouldAutoUpdate() {
  return shorebird_should_auto_update();
}

void RealUpdater::StartUpdateThread() {
  shorebird_start_update_thread();
}
#endif  // SHOREBIRD_PLATFORM_SUPPORTED

// MockUpdater implementation - for testing

bool MockUpdater::DoInit(const AppConfig& config) {
  init_count_++;
  last_release_version_ = config.release_version;
  last_yaml_config_ = config.yaml_config;
  call_log_.push_back("Init");
  return init_result_;
}

void MockUpdater::ValidateNextBootPatch() {
  validate_count_++;
  call_log_.push_back("ValidateNextBootPatch");
}

std::string MockUpdater::NextBootPatchPath() {
  call_log_.push_back("NextBootPatchPath");
  return next_boot_patch_path_;
}

void MockUpdater::DoReportLaunchStart() {
  launch_start_count_++;
  call_log_.push_back("ReportLaunchStart");
}

void MockUpdater::DoReportLaunchSuccess() {
  launch_success_count_++;
  call_log_.push_back("ReportLaunchSuccess");
}

void MockUpdater::DoReportLaunchFailure() {
  launch_failure_count_++;
  call_log_.push_back("ReportLaunchFailure");
}

bool MockUpdater::ShouldAutoUpdate() {
  call_log_.push_back("ShouldAutoUpdate");
  return should_auto_update_;
}

void MockUpdater::StartUpdateThread() {
  start_update_thread_count_++;
  call_log_.push_back("StartUpdateThread");
}

void MockUpdater::Reset() {
  init_count_ = 0;
  validate_count_ = 0;
  launch_start_count_ = 0;
  launch_success_count_ = 0;
  launch_failure_count_ = 0;
  start_update_thread_count_ = 0;
  init_result_ = true;
  should_auto_update_ = false;
  next_boot_patch_path_.clear();
  last_release_version_.clear();
  last_yaml_config_.clear();
  call_log_.clear();
}

}  // namespace shorebird
}  // namespace flutter
