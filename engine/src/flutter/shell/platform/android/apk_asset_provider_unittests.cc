// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/common/shorebird/shorebird.h"
#include "flutter/shell/platform/android/apk_asset_provider.h"
#include "gmock/gmock.h"
#include "gtest/gtest.h"

namespace flutter {
namespace testing {
class MockAPKAssetProviderImpl : public APKAssetProviderInternal {
 public:
  MOCK_METHOD(std::unique_ptr<fml::Mapping>,
              GetAsMapping,
              (const std::string& asset_name),
              (const, override));
};

TEST(APKAssetProvider, ShorebirdScopeIsCopiedFromTheFixedPackagedAsset) {
  auto impl = std::make_shared<MockAPKAssetProviderImpl>();
  const auto asset_name = ReleaseScopeAssetName("android", ShorebirdHostArch());
  EXPECT_CALL(*impl, GetAsMapping(asset_name))
      .WillOnce(::testing::Return(::testing::ByMove(
          std::make_unique<fml::DataMapping>("{\"scope\":\"packaged\"}"))));
  APKAssetProvider provider(impl);
  const AssetResolver& resolver = provider;
  std::string owned;
  ASSERT_TRUE(LoadCompiledReleaseScopeAsset(
      "android", ShorebirdHostArch(),
      [&resolver](const std::string& name) {
        return resolver.GetAsMapping(name);
      },
      &owned));
  EXPECT_EQ(owned, "{\"scope\":\"packaged\"}");
}

TEST(APKAssetProvider, CloneAndEquals) {
  auto first_provider = std::make_unique<APKAssetProvider>(
      std::make_shared<MockAPKAssetProviderImpl>());
  auto second_provider = std::make_unique<APKAssetProvider>(
      std::make_shared<MockAPKAssetProviderImpl>());
  auto third_provider = first_provider->Clone();

  ASSERT_NE(first_provider->GetImpl(), second_provider->GetImpl());
  ASSERT_EQ(first_provider->GetImpl(), third_provider->GetImpl());
  ASSERT_FALSE(*first_provider == *second_provider);
  ASSERT_TRUE(*first_provider == *third_provider);
}
}  // namespace testing
}  // namespace flutter
