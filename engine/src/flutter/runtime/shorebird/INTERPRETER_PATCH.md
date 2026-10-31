# Encrypted iOS interpreter patches

The reviewed AOT app snapshot always boots first. An updater-selected artifact
is read as data after the root isolate's libraries exist and before the isolate
is made runnable. The VM authenticates and decrypts the full bytecode snapshot,
then installs bytecode on retained functions. The plaintext is freed on success
and on every failure. No downloaded native instructions, JIT, or dynamic modules
are enabled by this path.

A rejected install destroys its transient isolate group. The runtime creates a
fresh base group for that launch and reports the patch as failed, so the updater
rolls back. Launch success is reported only after the actual user `main` returns, or its
returned `Future` completes successfully. A throwing main reports failure and
keeps the original unhandled-error behavior; a never-completing main remains
unconfirmed. Scheduling an entrypoint and rendering a frame are not startup
confirmation. An existing shared isolate group
uses its original installation and is never patched a second time.

The default VM profile supports a restricted set of retained function replacements.
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

## Complete-domain replacement profile

The signed compiled configuration opts in with
`aot_patch_full_replacement: true`, `aot_patch_host_abi` (64 lowercase hex),
and `aot_patch_replacement_base: shorebird_replacement_base.sbr`. Structural
updates and full replacement are mutually exclusive. The immutable base asset
must live directly in the signed `flutter_assets` directory. Its
`aot_patch_base_snapshot_hash` pins the SHA-256 of the **whole SBRPLCE wrapper**,
not the enclosed component.

The engine retains this configuration before initializing the updater. Every
fresh root group installs exactly one component after SDK libraries are set up
and before it becomes runnable: the process-selected authenticated update, or
the bundled base when no update is selected or the updater is unavailable. The
base is signed bundle data and requires no encrypted envelope or AES key. The
engine validates its bounded wrapper, whole-file hash and host stamp; the VM
validates the native baseline descriptor, root and complete mutable domain.
Profile mixing is rejected before VM replacement staging.

A rejected update destroys that group. The single fresh-group retry clears the
optional update while retaining the immutable base configuration. A rejected
base fails startup; inactive native application declarations are never a
fallback. Shared child groups retain their parent's committed installation.
Entrypoints and the plugin registrant are reacquired after replacement commits.

Focused native tests exercise configuration, one-artifact selection, opaque
wrapper forwarding, validation and payload release. They do not establish a
full-profile Flutter application launch or physical iOS device validation.
