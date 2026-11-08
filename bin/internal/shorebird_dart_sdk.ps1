# Copyright 2026 The Open Shorebird Authors. All rights reserved.
# Use of this source code is governed by a BSD-style license that can be
# found in the LICENSE file.

# Dot-sourced by update_dart_sdk.ps1. Keep this file consistent with
# shorebird_dart_sdk.sh, which documents the trust path and origin modes, and
# with the precedence table in shorebird-workspace
# docs/HARDENING_CONTRACTS.md section 8. Compatible with Windows PowerShell 5.

$shorebirdOpenProxyUrl = 'http://localhost:8080/download.flutter.io'
$shorebirdDartSdkLock = "$flutterRoot\bin\internal\shorebird_dart_sdk.pins"
$shorebirdDartSdkIdentity = "$cachePath\engine-dart-sdk.identity"

function Exit-ShorebirdError([string]$message, [string[]]$details = @()) {
    Write-Host ""
    Write-Host "Error: $message"
    foreach ($line in $details) { Write-Host "  $line" }
    Write-Host ""
    # Exit code 2 tells shared.bat not to retry: a configuration error.
    exit 2
}

function Get-ShorebirdTrimmed([string]$value) {
    if ($null -eq $value) { return '' }
    return $value.TrimEnd('/')
}

function Assert-ShorebirdImmutable([string]$name, [string]$url) {
    if ($url -match '/releases/latest(/|$)') {
        Exit-ShorebirdError "$name names a mutable `"latest`" release: $url" @(
            'Name an immutable release tag; the archive digest is pinned in bin/internal/shorebird_dart_sdk.pins.')
    }
}

# Returns @{ Mode = 'split'|'legacy-mirror'; Mirror = <url or ''> }.
function Resolve-ShorebirdOriginMode {
    $legacy = ''
    $legacyName = ''
    foreach ($name in @('SHOREBIRD_DOWNLOAD_URL', 'SHOREBIRD_FLUTTER_STORAGE_BASE_URL')) {
        $value = Get-ShorebirdTrimmed ([Environment]::GetEnvironmentVariable($name))
        if (-not $value) { continue }
        if ($legacy -and $legacy -ne $value) {
            Exit-ShorebirdError "Conflicting artifact mirror overrides: $legacyName=$legacy but $name=$value." @(
                'Both name a legacy all-in-one artifact mirror. Set one of them, or neither.')
        }
        $legacy = $value
        $legacyName = $name
    }
    $official = Get-ShorebirdTrimmed $Env:FLUTTER_STORAGE_BASE_URL
    if (-not $legacy -and $official -eq $shorebirdOpenProxyUrl) {
        $legacy = $official
        $legacyName = 'FLUTTER_STORAGE_BASE_URL'
    }
    $mode = $Env:SHOREBIRD_ORIGIN_MODE
    if (-not $mode) {
        if ($legacy) { $mode = 'legacy-mirror' } else { $mode = 'split' }
    } elseif ($mode -eq 'split') {
        if ($legacy) {
            Exit-ShorebirdError "SHOREBIRD_ORIGIN_MODE=split conflicts with $legacyName=$legacy, a legacy all-in-one mirror." @(
                'Unset the mirror variable, or set SHOREBIRD_ORIGIN_MODE=legacy-mirror.')
        }
    } elseif ($mode -eq 'legacy-mirror') {
        if (-not $legacy) {
            if ($official) { $legacy = $official } else { $legacy = $shorebirdOpenProxyUrl }
        }
    } else {
        Exit-ShorebirdError "Unknown SHOREBIRD_ORIGIN_MODE=$mode." @('Use split (default) or legacy-mirror.')
    }
    if ($mode -eq 'legacy-mirror' -and $official -and $official -ne $legacy) {
        Exit-ShorebirdError "Conflicting artifact origins: FLUTTER_STORAGE_BASE_URL=$official but the legacy all-in-one mirror is $legacy." @(
            'In legacy-mirror mode one mirror serves every artifact. Unset FLUTTER_STORAGE_BASE_URL or set it to the mirror.')
    }
    return @{ Mode = $mode; Mirror = $legacy }
}

# Returns the lock fields; Matches is true when its identity is this
# checkout's (engine.version and DEPS dart_sdk_revision).
function Read-ShorebirdDartSdkLock {
    $lock = @{ Engine = ''; Dart = ''; BaseUrl = ''; Assets = @{}; Matches = $false; CheckoutDart = '' }
    $deps = Get-Content "$flutterRoot\DEPS" | Select-String -Pattern '^\s*"dart_sdk_revision":\s*"([0-9a-f]{40})"' | Select-Object -First 1
    if ($deps) { $lock.CheckoutDart = $deps.Matches[0].Groups[1].Value }
    if (-not (Test-Path $shorebirdDartSdkLock)) { return $lock }
    $schema = ''
    $version = ''
    foreach ($raw in Get-Content $shorebirdDartSdkLock) {
        $fields = $raw.Trim() -split '\s+'
        switch ($fields[0]) {
            'schema' { $schema = $fields[1] }
            'contract_version' { $version = $fields[1] }
            'engine_revision' { $lock.Engine = $fields[1] }
            'dart_sdk_revision' { $lock.Dart = $fields[1] }
            'base_url' { $lock.BaseUrl = Get-ShorebirdTrimmed $fields[1] }
            'asset' { $lock.Assets[$fields[1]] = "$($fields[2]) $($fields[3])" }
        }
    }
    if ($schema -ne 'open-shorebird.dart-sdk-lock' -or $version -ne '1') {
        Exit-ShorebirdError "$shorebirdDartSdkLock is not an open-shorebird.dart-sdk-lock contract 1 file."
    }
    $lock.Matches = ($lock.Engine -eq $engineVersion -and $lock.CheckoutDart -and $lock.Dart -eq $lock.CheckoutDart)
    return $lock
}

# Returns "<sha256> <size>" pinned for archive $zip ('-' for an unknown size), or ''.
function Get-ShorebirdPinnedDigest($lock, [string]$zip) {
    $explicit = $Env:SHOREBIRD_DART_SDK_SHA256
    if ($explicit) {
        if ($explicit -cnotmatch '^[0-9a-f]{64}$') {
            Exit-ShorebirdError 'SHOREBIRD_DART_SDK_SHA256 must be 64 lowercase hex digits.'
        }
        return "$explicit -"
    }
    if ($lock.Matches -and $lock.Assets.ContainsKey($zip)) { return $lock.Assets[$zip] }
    return ''
}

# True when bin/cache/dart-sdk must be (re)installed.
function Test-ShorebirdDartSdkNeedsUpdate {
    if (-not (Test-Path $engineStamp) -or $engineVersion -ne (Get-Content $engineStamp)) { return $true }
    # A stamp without an identity is an SDK provisioned outside this script (a
    # local engine build); it is kept, as before.
    if (-not (Test-Path $shorebirdDartSdkIdentity)) { return $false }
    $installed = (Get-Content $shorebirdDartSdkIdentity -TotalCount 1).Trim() -split '\s+'
    Resolve-ShorebirdOriginMode | Out-Null
    $lock = Read-ShorebirdDartSdkLock
    if ($installed[0] -ne $engineVersion) { return $true }
    if ($lock.CheckoutDart -and $installed[1] -ne $lock.CheckoutDart) { return $true }
    $pinned = Get-ShorebirdPinnedDigest $lock $installed[2]
    # Offline reuse: nothing newer is pinned, so the verified install stands.
    if (-not $pinned) { return $false }
    return ($installed[3] -ne ($pinned -split ' ')[0])
}

# Returns $true when $path matches "<sha256> <size>".
function Test-ShorebirdArchive([string]$path, [string]$pin) {
    $expected = $pin -split ' '
    if ($expected[1] -ne '-') {
        $size = (Get-Item $path).Length
        if ("$size" -ne $expected[1]) {
            Write-Host "Refusing ${path}: size $size does not match the pinned $($expected[1])."
            return $false
        }
    }
    $actual = (Get-FileHash -Algorithm SHA256 -Path $path).Hash.ToLowerInvariant()
    if ($actual -ne $expected[0]) {
        Write-Host "Refusing ${path}: sha256 $actual does not match the pinned $($expected[0])."
        return $false
    }
    return $true
}

# Returns @{ Url; Pin; Identity; Zip } for the host archive, or exits with the
# reason none is usable. $zipNames is the preference order (ARM64, then x64).
function Resolve-ShorebirdDartSdk([string[]]$zipNames) {
    $origin = Resolve-ShorebirdOriginMode
    $lock = Read-ShorebirdDartSdkLock
    $zip = $zipNames[0]
    if (-not $Env:SHOREBIRD_DART_SDK_SHA256) {
        # Prefer the first archive the lock publishes, as the ARM64 probe did.
        foreach ($candidate in $zipNames) {
            if ($lock.Matches -and $lock.Assets.ContainsKey($candidate)) { $zip = $candidate; break }
        }
        if ($zip -ne $zipNames[0]) {
            Write-Host "The pinned Dart SDK has no $($zipNames[0]), falling back to $zip..."
        }
    }
    $layoutPath = "flutter_infra_release/flutter/$engineVersion/$zip"
    $url = ''
    if ($origin.Mode -eq 'legacy-mirror') {
        $base = $origin.Mirror
        if ($engineRealm) { $base = "$base/$engineRealm" }
        $url = "$base/$layoutPath"
    } elseif ($Env:SHOREBIRD_DART_SDK_RELEASE_BASE_URL) {
        $base = Get-ShorebirdTrimmed $Env:SHOREBIRD_DART_SDK_RELEASE_BASE_URL
        Assert-ShorebirdImmutable 'SHOREBIRD_DART_SDK_RELEASE_BASE_URL' $base
        $url = "$base/$zip"
    } elseif ($Env:SHOREBIRD_ARTIFACT_BASE_URL) {
        $url = "$(Get-ShorebirdTrimmed $Env:SHOREBIRD_ARTIFACT_BASE_URL)/shorebird/$layoutPath"
    } elseif ($lock.Matches -and $lock.BaseUrl) {
        Assert-ShorebirdImmutable "$shorebirdDartSdkLock base_url" $lock.BaseUrl
        $url = "$($lock.BaseUrl)/$zip"
    }
    $pin = Get-ShorebirdPinnedDigest $lock $zip
    if ($origin.Mode -eq 'split' -and (-not $url -or -not $pin)) {
        if (-not $lock.Matches) {
            $why = "bin/internal/shorebird_dart_sdk.pins pins engine $($lock.Engine) and Dart SDK $($lock.Dart), but this checkout pins engine $engineVersion and Dart SDK $($lock.CheckoutDart)."
        } elseif (-not $lock.BaseUrl) {
            $why = "bin/internal/shorebird_dart_sdk.pins is unpublished: no verified archive exists yet for engine $engineVersion and Dart SDK $($lock.CheckoutDart)."
        } else {
            $why = "bin/internal/shorebird_dart_sdk.pins publishes no $zip for this host."
        }
        Exit-ShorebirdError "No verified custom Dart SDK ($zip) for this Flutter checkout." @(
            $why,
            'This SDK is patched; a stock Dart SDK is never substituted. Options:',
            '- use a Flutter revision whose lock is published;',
            '- serve the archive from SHOREBIRD_ARTIFACT_BASE_URL and pin it with SHOREBIRD_DART_SDK_SHA256;',
            '- install a locally built SDK into bin/cache/dart-sdk;',
            '- or SHOREBIRD_ORIGIN_MODE=legacy-mirror with an artifact proxy (compatibility only).')
    }
    $checkoutDart = $lock.CheckoutDart
    if (-not $checkoutDart) { $checkoutDart = '-' }
    if ($pin) {
        $identity = "$engineVersion $checkoutDart $zip $(($pin -split ' ')[0])"
    } else {
        if ($origin.Mode -eq 'legacy-mirror' -and $zipNames.Count -gt 1) {
            # No pin to choose by: keep the original availability probe.
            Try {
                Invoke-WebRequest -Uri "$($url.Substring(0, $url.Length - $zip.Length))$($zipNames[0])" -UseBasicParsing -Method Head | Out-Null
            } Catch {
                Write-Host "The current channel's Dart SDK does not support $($zipNames[0]), falling back to $($zipNames[1])..."
                $zip = $zipNames[1]
                $url = "$($url.Substring(0, $url.Length - $zipNames[0].Length))$zip"
            }
        }
        Write-Host ""
        Write-Host "WARNING: installing an UNVERIFIED Dart SDK from the legacy all-in-one mirror"
        Write-Host "  $url"
        Write-Host "  No digest is pinned for engine $engineVersion. Publish the lock or set SHOREBIRD_DART_SDK_SHA256."
        Write-Host ""
        $identity = "$engineVersion $checkoutDart $zip unverified"
    }
    return @{ Url = $url; Pin = $pin; Identity = $identity; Zip = $zip }
}

# Downloads (or reuses) the archive at $archive and verifies it. A verified
# archive already there is reused without any network access.
function Get-ShorebirdDartSdkArchive($resolved, [string]$archive) {
    if ($resolved.Pin -and (Test-Path $archive)) {
        if (Test-ShorebirdArchive $archive $resolved.Pin) {
            Write-Host "Reusing the verified Dart SDK archive $archive."
            return
        }
        Remove-Item $archive
    }
    $partial = "$archive.partial"
    if (Test-Path $partial) { Remove-Item $partial }
    Try {
        Import-Module BitsTransfer
        $ProgressPreference = 'SilentlyContinue'
        Start-BitsTransfer -Source $resolved.Url -Destination $partial -ErrorAction Stop
    }
    Catch {
        Write-Host "Downloading the Dart SDK using the BITS service failed, retrying with WebRequest..."
        # Invoke-WebRequest is very slow when the progress bar is visible.
        # https://github.com/flutter/flutter/issues/37789
        $OriginalProgressPreference = $ProgressPreference
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $resolved.Url -OutFile $partial
        $ProgressPreference = $OriginalProgressPreference
    }
    if ($resolved.Pin -and -not (Test-ShorebirdArchive $partial $resolved.Pin)) {
        Remove-Item $partial
        Exit-ShorebirdError "The Dart SDK archive from $($resolved.Url) does not match its pinned digest." @(
            'It was deleted without being unpacked or run. The mirror or release serves different bytes.')
    }
    Move-Item -Force $partial $archive
}
