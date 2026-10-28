// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/runtime/shorebird/patch_cache.h"

#include <string>
#include <vector>

#include "flutter/shell/common/shorebird/updater.h"
#include "gtest/gtest.h"

namespace flutter {
namespace testing {

TEST(PatchCache, InstanceReturnsSameInstance) {
  PatchCache& instance1 = PatchCache::Instance();
  PatchCache& instance2 = PatchCache::Instance();
  EXPECT_EQ(&instance1, &instance2);
}

// Loaded ELF snapshots are covered end to end. These cases check path
// selection and recovery when the updater selects a missing patch.

TEST(TryLoadFromPatch, ReturnsNullptrForEmptyPaths) {
  std::vector<std::string> empty_paths;
  auto result = TryLoadFromPatch(empty_paths, PatchSymbol::kIsolateData);
  EXPECT_EQ(result, nullptr);
}

TEST(TryLoadFromPatch, ReturnsNullptrForNonVmcodePath) {
  std::vector<std::string> paths = {"/path/to/some/file.so"};
  auto result = TryLoadFromPatch(paths, PatchSymbol::kIsolateData);
  EXPECT_EQ(result, nullptr);
}

TEST(TryLoadFromPatch, ChecksOnlyFirstPath) {
  // Only the first path should be checked for .vmcode extension
  std::vector<std::string> paths = {"/path/to/regular.so",
                                    "/path/to/patch.vmcode"};
  auto result = TryLoadFromPatch(paths, PatchSymbol::kIsolateInstructions);
  // Should return nullptr because first path is not .vmcode
  EXPECT_EQ(result, nullptr);
}

TEST(PatchCache, GetOrLoadReturnsNullptrForNonexistentFile) {
  auto result =
      PatchCache::Instance().GetOrLoad("/nonexistent/path/to/file.vmcode");
  EXPECT_EQ(result, nullptr);
}

TEST(TryLoadFromPatch, MissingPatchFallsBackAndReportsFailureOnce) {
  auto mock = std::make_unique<shorebird::MockUpdater>();
  auto* mock_ptr = mock.get();
  shorebird::Updater::SetInstanceForTesting(std::move(mock));
  shorebird::Updater::ResetLaunchStateForTesting();
  shorebird::Updater::Instance().ReportLaunchStart();

  const std::vector<std::string> paths = {"/nonexistent/patch.vmcode"};
  EXPECT_EQ(TryLoadFromPatch(paths, PatchSymbol::kIsolateData), nullptr);
  EXPECT_EQ(TryLoadFromPatch(paths, PatchSymbol::kIsolateInstructions),
            nullptr);
  EXPECT_EQ(mock_ptr->launch_failure_count(), 1);
  EXPECT_EQ(mock_ptr->launch_start_count(), 1);

  shorebird::Updater::ResetInstanceForTesting();
  shorebird::Updater::ResetLaunchStateForTesting();
}

}  // namespace testing
}  // namespace flutter
