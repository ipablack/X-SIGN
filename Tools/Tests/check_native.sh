#!/usr/bin/env bash
set -euo pipefail
check() {
  local label="$1"
  shift
  printf "Starting native check: %s\n" "$label"
  "$@" || {
    local status="$?"
    printf '::error title=%s::Native check failed (exit %s). Read the preceding output.\n' "$label" "$status"
    exit "$status"
  }
}
command -v xcrun >/dev/null
swiftc="$(xcrun --sdk macosx --find swiftc)"
sdk="$(xcrun --sdk macosx --show-sdk-path)"
host_arch="$(uname -m)"

check "Prepare catalogue policy checks" python3 Tools/Tests/prepare_source_selection_checks.py
check "Compile Catalogue and source policies" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library "$RUNNER_TEMP/xsign-source-policy.swift" Feather/Utilities/XSignCatalogueEndpoint.swift Feather/Utilities/XSignAppMetadata.swift Feather/Utilities/XSignImportLink.swift Feather/Utilities/XSignRESTSource.swift Feather/Utilities/XSignSourceAdapter.swift Feather/Utilities/XSignSelfUpdatePolicy.swift AltSourceKit/Sources/AltSourceKit/Models/ASRepository.swift AltSourceKit/Sources/AltSourceKit/Extensions/Array/Array+safe.swift AltSourceKit/Sources/AltSourceKit/Extensions/Color/Color+Codable.swift Tools/Tests/xsign_source_selection_checks.swift -o "$RUNNER_TEMP/xsign-source-checks"
check "Catalogue and source policies" "$RUNNER_TEMP/xsign-source-checks"
check "Compile Certificate selection" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library Feather/Utilities/XSignCertificateSelection.swift Tools/Tests/xsign_certificate_selection_checks.swift -o "$RUNNER_TEMP/xsign-certificate-checks"
check "Certificate selection" "$RUNNER_TEMP/xsign-certificate-checks"
check "Compile Private storage" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library Feather/Utilities/XSignPrivateFiles.swift Tools/Tests/xsign_private_storage_checks.swift -o "$RUNNER_TEMP/xsign-private-storage-checks"
check "Private storage" "$RUNNER_TEMP/xsign-private-storage-checks"
check "Compile Owned staging paths" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/IDeviceOwnedStaging.swift Tools/Tests/xsign_owned_staging_checks.swift -o "$RUNNER_TEMP/xsign-staging-checks"
check "Owned staging paths" "$RUNNER_TEMP/xsign-staging-checks"
check "Compile Local transfer" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library IDeviceKitten/Sources/IDeviceSwift/InstallationProxy/IDeviceFileTransfer.swift Tools/Tests/xsign_local_transfer_checks.swift -o "$RUNNER_TEMP/xsign-transfer-checks"
check "Local transfer" "$RUNNER_TEMP/xsign-transfer-checks"
check "Compile Self-update identity" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library Feather/Utilities/XSignSelfUpdatePolicy.swift Tools/Tests/xsign_self_update_policy_checks.swift -o "$RUNNER_TEMP/xsign-self-update-checks"
check "Self-update identity" "$RUNNER_TEMP/xsign-self-update-checks"
check "Prepare self-update key fixture" python3 Tools/Tests/make_self_update_key_fixture.py
check "Compile Self-update key matching" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library Feather/Utilities/XSignSelfUpdateKey.swift Tools/Tests/xsign_self_update_key_checks.swift -o "$RUNNER_TEMP/xsign-self-update-key-checks"
check "Self-update key matching" "$RUNNER_TEMP/xsign-self-update-key-checks"
check "Signing option compatibility" python3 Tools/Tests/check_options_compat.py
check "Compile Batch profile policy" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library Feather/Utilities/XSignProvisioningProfile.swift Feather/Utilities/XSignBatchQueue.swift Tools/Tests/xsign_batch_profile_checks.swift -o "$RUNNER_TEMP/xsign-batch-profile-checks"
check "Batch profile policy" "$RUNNER_TEMP/xsign-batch-profile-checks"
check "Zsign provisioning" python3 Tools/Tests/check_zsign_provisioning.py
check "Prepare local signing server checks" python3 Tools/Tests/prepare_local_signing_server_checks.py
check "Prepare IPA security fixtures" python3 Tools/Tests/make_ipa_security_fixtures.py
check "Local signing server, IPA extraction and OTA" env XSIGN_IPA_FIXTURES="$RUNNER_TEMP/xsign-ipa-fixtures" swift run --package-path "$RUNNER_TEMP/xsign-local-server-checks" --jobs 2 XSignLocalServerChecks
check "Compile App Store URL handling" "$swiftc" -sdk "$sdk" -target "$host_arch-apple-macos14.0" -swift-version 5 -parse-as-library Feather/Utilities/XSignSearch.swift Feather/Utilities/XSignIPAProvider.swift Tools/Tests/xsign_appstore_provider_checks.swift -o "$RUNNER_TEMP/xsign-appstore-provider-checks"
check "App Store URL handling" "$RUNNER_TEMP/xsign-appstore-provider-checks"
check "Whitespace verification" git diff --check
