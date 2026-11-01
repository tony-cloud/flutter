// Copyright 2026 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef FLUTTER_SHELL_PLATFORM_ANDROID_SHOREBIRD_RELEASE_SCOPE_H_
#define FLUTTER_SHELL_PLATFORM_ANDROID_SHOREBIRD_RELEASE_SCOPE_H_

#include <jni.h>
#include <string>

namespace flutter {
// Reads only the fixed, bounded scope for this engine architecture from the
// installed APK. The output owns its bytes after Java/AssetManager refs expire.
bool LoadShorebirdReleaseScopeFromAPK(JNIEnv* env,
                                      jobject context,
                                      std::string* scope_json);
}  // namespace flutter
#endif
