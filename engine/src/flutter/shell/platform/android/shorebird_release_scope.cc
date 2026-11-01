// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "flutter/shell/platform/android/shorebird_release_scope.h"

#include "flutter/fml/platform/android/scoped_java_ref.h"
#include "flutter/shell/common/shorebird/shorebird.h"
#include "flutter/shell/platform/android/apk_asset_provider.h"

namespace flutter {
bool LoadShorebirdReleaseScopeFromAPK(JNIEnv* env,
                                      jobject context,
                                      std::string* scope_json) {
  if (!scope_json)
    return false;
  scope_json->clear();
  if (!env || !context)
    return false;
  fml::jni::ScopedJavaLocalRef<jclass> context_class(
      env, env->GetObjectClass(context));
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return false;
  }
  const auto get_assets =
      context_class.obj()
          ? env->GetMethodID(context_class.obj(), "getAssets",
                             "()Landroid/content/res/AssetManager;")
          : nullptr;
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return false;
  }
  if (!get_assets)
    return false;
  fml::jni::ScopedJavaLocalRef<jobject> assets(
      env, env->CallObjectMethod(context, get_assets));
  if (env->ExceptionCheck()) {
    env->ExceptionClear();
    return false;
  }
  if (!assets.obj())
    return false;
  APKAssetProvider provider(env, assets.obj(), "flutter_assets", 64 * 1024);
  const AssetResolver& resolver = provider;
  return LoadCompiledReleaseScopeAsset(
      "android", ShorebirdHostArch(),
      [&resolver](const std::string& name) {
        return resolver.GetAsMapping(name);
      },
      scope_json);
}
}  // namespace flutter
