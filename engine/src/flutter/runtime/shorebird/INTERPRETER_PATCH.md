# Encrypted iOS interpreter patches

The reviewed AOT app snapshot always boots first. An updater-selected artifact
is read as data after the root isolate's libraries exist and before the isolate
is made runnable. The VM authenticates and decrypts the full bytecode snapshot,
then installs bytecode on retained functions. The plaintext is freed on success
and on every failure. No downloaded native instructions, JIT, or dynamic modules
are enabled by this path.

A rejected install destroys its transient isolate group. The runtime creates a
fresh base group for that launch and reports the patch as failed, so the updater
rolls back. Launch success is reported only after the root entrypoint invocation
succeeds. This is not a first-frame watchdog. An existing shared isolate group
uses its original installation and is never patched a second time.

The current VM supports a restricted set of retained function replacements.
A full-snapshot payload does not mean arbitrary library/class/closure/signature
changes are supported. The release and patch compilers must preserve the same
interpreter-compatible metadata and reachability policy; unsupported changes
must be rejected rather than advertised as installed.

## Native key provisioning

Register once before creating any Flutter project or engine. Swift imports the
public method as:

```swift
let registered = FlutterDartProject.setShorebirdAotPatchKeyProvider { keyID in
  // Application-owned lookup: require an entitled account and a known key ID.
  // Return a 32-byte Data from Keychain, or nil. Never fetch keys here.
  return accountKeyStore.provisionedPatchKey(for: keyID)
}
precondition(registered)
```

`accountKeyStore` above is application code, not an engine service. Provisioning,
account authorization, key rotation/revocation, and Keychain access policy belong
to the application. The engine does not ship a production key or a key endpoint.
Do not return the same key indiscriminately for arbitrary IDs. Registration is
sealed when the first project initializes; the retained callback is immutable
for the process lifetime. It can run on the UI thread and must not do network I/O.
Neither keys nor decrypted artifacts belong in YAML, assets, defines, or logs.

## Signed baseline expectations

The compiled, app-signed `shorebird.yaml` contains the resolved `app_id` and:

- `aot_patch_runtime_mode: dart-bytecode-interpreter`
- `aot_patch_app_build_id` (defaults to the actual bundle version+build number)
- `aot_patch_base_flavor_id`, `aot_patch_base_license_type`
- `aot_patch_sdk_hash`, `aot_patch_base_snapshot_hash`
- `aot_patch_key_id`, optional `aot_patch_obfuscation_map_hash`
- optional `aot_patch_flavor_id`, `aot_patch_license_type` target restrictions
- pinned `patch_public_key`, `patch_verification: strict`, and
  `patch_response_verification: required`

The base snapshot hash is the release bytecode SHA-256 used by the public patch
format. It cannot be reconstructed from the native AOT snapshot. The release
build must persist the correct expectation before signing the final app bundle.
The future patch hash comes from the authenticated envelope, and the VM compares
it with the actual decrypted full-snapshot bytes. It is not a baseline constant.

Base flavor/license are pinned. When target restrictions are absent, the
signature-verified envelope's target is authorized by the app supplying its
provisioned key. This permits a deliberate free-to-pro transition. Explicit
bundled target restrictions further limit accepted targets. The key provider is
responsible for entitlement enforcement; possession of an arbitrary key ID does
not itself prove an account has a license.

The compiled YAML allowlist excludes raw AES keys, patch build paths and future
patch hashes. Interpreter compilation requires a publisher pin and forces both
verification modes. Legacy native builds may explicitly retain optional response
verification for compatibility.
