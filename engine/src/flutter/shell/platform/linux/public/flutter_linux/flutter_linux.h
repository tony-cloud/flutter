// Copyright 2013 The Flutter Authors. All rights reserved.
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef FLUTTER_SHELL_PLATFORM_LINUX_PUBLIC_FLUTTER_LINUX_FLUTTER_LINUX_H_
#define FLUTTER_SHELL_PLATFORM_LINUX_PUBLIC_FLUTTER_LINUX_FLUTTER_LINUX_H_


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

#define __FLUTTER_LINUX_INSIDE__

#include <flutter_linux/fl_application.h>
#include <flutter_linux/fl_basic_message_channel.h>
#include <flutter_linux/fl_binary_codec.h>
#include <flutter_linux/fl_binary_messenger.h>
#include <flutter_linux/fl_dart_project.h>
#include <flutter_linux/fl_engine.h>
#include <flutter_linux/fl_event_channel.h>
#include <flutter_linux/fl_json_message_codec.h>
#include <flutter_linux/fl_json_method_codec.h>
#include <flutter_linux/fl_message_codec.h>
#include <flutter_linux/fl_method_call.h>
#include <flutter_linux/fl_method_channel.h>
#include <flutter_linux/fl_method_codec.h>
#include <flutter_linux/fl_method_response.h>
#include <flutter_linux/fl_pixel_buffer_texture.h>
#include <flutter_linux/fl_plugin_registrar.h>
#include <flutter_linux/fl_plugin_registry.h>
#include <flutter_linux/fl_standard_message_codec.h>
#include <flutter_linux/fl_standard_method_codec.h>
#include <flutter_linux/fl_string_codec.h>
#include <flutter_linux/fl_texture.h>
#include <flutter_linux/fl_texture_gl.h>
#include <flutter_linux/fl_texture_registrar.h>
#include <flutter_linux/fl_value.h>
#include <flutter_linux/fl_view.h>

#undef __FLUTTER_LINUX_INSIDE__

#endif  // FLUTTER_SHELL_PLATFORM_LINUX_PUBLIC_FLUTTER_LINUX_FLUTTER_LINUX_H_
