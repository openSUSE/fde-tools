#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    . "$SHAREDIR/ui/shell"
    . "$SHAREDIR/util"
    . "$SHAREDIR/uefi"
}

teardown() {
    teardown_fde_env
}

@test "UT-UE01: uefi_get_current_loader resolves path, falls back, or fails" {
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    mkdir -p "$FDE_ESP_DIR/EFI/BOOT"

    # Case 1: fde-boot-loader succeeds with valid path
    echo "EFI/opensuse/shim.efi" > "$MOCK_DIR/fde-boot-loader.out"
    touch "$FDE_ESP_DIR/EFI/opensuse/shim.efi"
    run uefi_get_current_loader
    assert_success
    assert_equal "$output" "$(realpath "$FDE_ESP_DIR/EFI/opensuse/shim.efi")"

    # Case 2: fde-boot-loader prints empty output -> fallback to EFI/BOOT/boot*.efi
    : > "$MOCK_DIR/fde-boot-loader.out"
    local boot_efi
    if [ "$(uname -m)" = "aarch64" ]; then
        boot_efi="bootaa64.efi"
    else
        boot_efi="bootx64.efi"
    fi
    touch "$FDE_ESP_DIR/EFI/BOOT/$boot_efi"
    run uefi_get_current_loader
    assert_success
    assert_equal "$output" "$(realpath "$FDE_ESP_DIR/EFI/BOOT/$boot_efi")"

    # Case 3: fde-boot-loader fails (rc 1)
    echo 1 > "$MOCK_DIR/fde-boot-loader.rc"
    run uefi_get_current_loader
    assert_failure 1

    # Case 4: fde-boot-loader empty and no fallback file
    rm -f "$FDE_ESP_DIR/EFI/BOOT/$boot_efi"
    echo 0 > "$MOCK_DIR/fde-boot-loader.rc"
    : > "$MOCK_DIR/fde-boot-loader.out"
    run uefi_get_current_loader
    assert_failure 1
}

@test "UT-UE01: uefi_get_current_efidir respects explicit directory or derives from loader" {
    mkdir -p "$FDE_ESP_DIR/EFI/custom"

    # Explicit FDE_UEFI_BOOTDIR set
    uefi_set_loader "$FDE_ESP_DIR/EFI/custom"
    run uefi_get_current_efidir
    assert_success
    assert_equal "$output" "$(realpath "$FDE_ESP_DIR/EFI/custom")"

    # Derived from uefi_get_current_loader
    uefi_set_loader ""
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    touch "$FDE_ESP_DIR/EFI/opensuse/shim.efi"
    echo "EFI/opensuse/shim.efi" > "$MOCK_DIR/fde-boot-loader.out"
    echo 0 > "$MOCK_DIR/fde-boot-loader.rc"
    run uefi_get_current_efidir
    assert_success
    assert_equal "$output" "$(realpath "$FDE_ESP_DIR/EFI/opensuse")"
}

@test "UT-UE02: uefi_secure_boot_enabled checks sysfs and mokutil" {
    # Case 1: no /sys/firmware/efi
    rm -rf "$FDE_SYSFS/firmware/efi"
    run uefi_secure_boot_enabled
    assert_failure 1

    # Case 2: /sys/firmware/efi exists, mokutil reports enabled
    mkdir -p "$FDE_SYSFS/firmware/efi"
    echo "SecureBoot enabled" > "$MOCK_DIR/mokutil.out"
    run uefi_secure_boot_enabled
    assert_success

    # Case 3: mokutil reports disabled
    echo "SecureBoot disabled" > "$MOCK_DIR/mokutil.out"
    run uefi_secure_boot_enabled
    assert_failure 1
}
