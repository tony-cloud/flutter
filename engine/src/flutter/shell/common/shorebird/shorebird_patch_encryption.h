// Copyright 2026 The Flutter Authors. All rights reserved.
// BSD-style license: see LICENSE.

// Open Shorebird encrypted-delivery key lookup. Register before any Flutter
// engine initializes the updater. The callback runs on updater workers and must
// remain valid for the process lifetime. Return a provisioned 32-byte per-patch
// key for key_id + authenticated AAD; never return a server master secret.
#ifndef FLUTTER_SHOREBIRD_PATCH_DECRYPTION_API_
#define FLUTTER_SHOREBIRD_PATCH_DECRYPTION_API_
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef bool (*FlutterShorebirdPatchDecryptionKeyProvider)(
    const char* key_id, const char* aad, uint8_t* key_out,
    size_t capacity, size_t* written);
// Non-null enables required encrypted delivery; null disables it before init.
// Returns false after initialization. Requires strict signed-response policies.
bool shorebird_set_patch_decryption_key_provider(
    FlutterShorebirdPatchDecryptionKeyProvider provider);
#ifdef __cplusplus
}
#endif
#endif  // FLUTTER_SHOREBIRD_PATCH_DECRYPTION_API_
