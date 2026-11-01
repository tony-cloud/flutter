// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#include "flutter/shell/platform/android/apk_asset_provider.h"

#include <unistd.h>

#include <algorithm>
#include <sstream>
#include <utility>

#include "flutter/assets/asset_resolver.h"
#include "flutter/fml/logging.h"

namespace flutter {

class APKAssetMapping : public fml::Mapping {
 public:
  explicit APKAssetMapping(AAsset* asset) : asset_(asset) {}

  ~APKAssetMapping() override { AAsset_close(asset_); }

  size_t GetSize() const override { return AAsset_getLength(asset_); }

  const uint8_t* GetMapping() const override {
    return reinterpret_cast<const uint8_t*>(AAsset_getBuffer(asset_));
  }

  bool IsDontNeedSafe() const override { return !AAsset_isAllocated(asset_); }

 private:
  AAsset* const asset_;

  FML_DISALLOW_COPY_AND_ASSIGN(APKAssetMapping);
};

class APKAssetProviderImpl : public APKAssetProviderInternal {
 public:
  explicit APKAssetProviderImpl(JNIEnv* env,
                                jobject jassetManager,
                                std::string directory,
                                size_t max_asset_bytes)
      : java_asset_manager_(env, jassetManager),
        directory_(std::move(directory)),
        max_asset_bytes_(max_asset_bytes) {
    asset_manager_ = AAssetManager_fromJava(env, jassetManager);
  }

  ~APKAssetProviderImpl() = default;

  std::unique_ptr<fml::Mapping> GetAsMapping(
      const std::string& asset_name) const override {
    std::stringstream ss;
    ss << directory_.c_str() << "/" << asset_name;
    if (max_asset_bytes_ && !asset_manager_)
      return nullptr;
    AAsset* asset = AAssetManager_open(
        asset_manager_, ss.str().c_str(),
        max_asset_bytes_ ? AASSET_MODE_STREAMING : AASSET_MODE_BUFFER);
    if (!asset) {
      return nullptr;
    }
    // Check the full length before getBuffer can decompress/allocate a scope.
    // Ordinary providers preserve their existing uncapped behavior.
    if (max_asset_bytes_) {
      const auto length = AAsset_getLength64(asset);
      if (length < 0 || static_cast<uint64_t>(length) > max_asset_bytes_) {
        AAsset_close(asset);
        return nullptr;
      }
    }
    return std::make_unique<APKAssetMapping>(asset);
  };

 private:
  fml::jni::ScopedJavaGlobalRef<jobject> java_asset_manager_;
  AAssetManager* asset_manager_;
  const std::string directory_;
  const size_t max_asset_bytes_;

  FML_DISALLOW_COPY_AND_ASSIGN(APKAssetProviderImpl);
};

APKAssetProvider::APKAssetProvider(JNIEnv* env,
                                   jobject assetManager,
                                   std::string directory,
                                   size_t max_asset_bytes)
    : impl_(std::make_shared<APKAssetProviderImpl>(env,
                                                   assetManager,
                                                   std::move(directory),
                                                   max_asset_bytes)) {}

APKAssetProvider::APKAssetProvider(
    std::shared_ptr<APKAssetProviderInternal> impl)
    : impl_(std::move(impl)) {}

// |AssetResolver|
bool APKAssetProvider::IsValid() const {
  return true;
}

// |AssetResolver|
bool APKAssetProvider::IsValidAfterAssetManagerChange() const {
  return true;
}

// |AssetResolver|
AssetResolver::AssetResolverType APKAssetProvider::GetType() const {
  return AssetResolver::AssetResolverType::kApkAssetProvider;
}

// |AssetResolver|
std::unique_ptr<fml::Mapping> APKAssetProvider::GetAsMapping(
    const std::string& asset_name) const {
  return impl_->GetAsMapping(asset_name);
}

std::unique_ptr<APKAssetProvider> APKAssetProvider::Clone() const {
  return std::make_unique<APKAssetProvider>(impl_);
}

bool APKAssetProvider::operator==(const AssetResolver& other) const {
  auto other_provider = other.as_apk_asset_provider();
  if (!other_provider) {
    return false;
  }
  return impl_ == other_provider->impl_;
}

}  // namespace flutter
