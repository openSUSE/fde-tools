#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    . "$SHAREDIR/ui/shell"
    . "$SHAREDIR/util"
    . "$SHAREDIR/uefi"
    . "$SHAREDIR/tpm"
    . "$SHAREDIR/grub2"
}

teardown() {
    teardown_fde_env
}

@test "UT-G01: grub_get_fde_password from defaults, fallback grub.cfg, or failure" {
    # Case 1: In /etc/default/grub
    echo 'GRUB_CRYPTODISK_PASSWORD="from_default_grub"' > "$FDE_GRUB_DEFAULTS"
    run grub_get_fde_password
    assert_success
    assert_output "from_default_grub"

    # Case 2: Fallback in ESP/EFI/BOOT/grub.cfg
    echo 'GRUB_DISTRIBUTOR="openSUSE"' > "$FDE_GRUB_DEFAULTS"
    mkdir -p "$FDE_ESP_DIR/EFI/BOOT"
    cp "$REPO/test/fixtures/grub.cfg.with-pw" "$FDE_ESP_DIR/EFI/BOOT/grub.cfg"
    run grub_get_fde_password
    assert_success
    assert_output "embedded_test_password"

    # Case 3: Neither GRUB_CRYPTODISK_PASSWORD nor cryptomount password exists
    cp "$REPO/test/fixtures/grub.cfg.no-pw" "$FDE_ESP_DIR/EFI/BOOT/grub.cfg"
    run grub_get_fde_password
    assert_failure 1
}

@test "UT-G02: grub_set_fde_password clears or round-trips special characters" {
    # Set with special characters
    local special='pw|with&special/chars\end'
    grub_set_fde_password "$special"
    run grub_get_fde_password
    assert_success
    assert_output "$special"

    # Clear password
    grub_set_fde_password ""
    run grub_get_fde_password
    assert_failure 1
}

@test "UT-G03: grub_commit_config uses --removable only when EFI contains only BOOT" {
    # Removable layout: only EFI/BOOT exists
    rm -rf "$FDE_ESP_DIR/EFI"
    mkdir -p "$FDE_ESP_DIR/EFI/BOOT"
    grub_commit_config
    assert_mock_called "shim-install --no-grub-install --removable"

    # Non-removable layout: EFI/BOOT and EFI/opensuse exist
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    : > "$MOCK_LOG"
    grub_commit_config
    assert_mock_called "shim-install --no-grub-install"
    assert_mock_not_called "--removable"
}

@test "UT-G04: grub_update_early_config sets variables and commits" {
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    grub_update_early_config "sealed.tpm" "sha256"

    . "$FDE_GRUB_DEFAULTS"
    assert_equal "$GRUB_ENABLE_CRYPTODISK" "y"
    assert_equal "$GRUB_TPM2_SEALED_KEY" "sealed.tpm"
    assert_equal "$GRUB_TPM2_SRK_ALG" "sha256"
    assert_mock_called "shim-install --no-grub-install"
}

@test "UT-G05: grub_repair_srk_alg no-op when equal, updates and commits when differ" {
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    echo 'GRUB_TPM2_SRK_ALG="RSA2048"' > "$FDE_GRUB_DEFAULTS"

    # Mock tpm_get_srk_alg returning RSA2048 (matches)
    tpm_get_srk_alg() { echo "RSA2048"; return 0; }
    : > "$MOCK_LOG"
    run grub_repair_srk_alg "dummy.key"
    assert_success
    assert_mock_not_called "shim-install"

    # Now mock returning ECC (differs)
    tpm_get_srk_alg() { echo "ECC"; return 0; }
    run grub_repair_srk_alg "dummy.key"
    assert_success
    . "$FDE_GRUB_DEFAULTS"
    assert_equal "$GRUB_TPM2_SRK_ALG" "ECC"
    assert_mock_called "shim-install"

    # If commit fails, grub_repair_srk_alg returns 1
    echo 1 > "$MOCK_DIR/shim-install.rc"
    tpm_get_srk_alg() { echo "RSA3072"; return 0; }
    run grub_repair_srk_alg "dummy.key"
    assert_failure 1
}

@test "UT-G06: grub_check_sealed_key verifies sealed key under PCR and AP modes" {
    local efidir="$FDE_ESP_DIR/EFI/opensuse"
    mkdir -p "$efidir"
    uefi_set_loader "$efidir"

    # No sealed key file -> rc 1
    run grub_check_sealed_key
    assert_failure 1

    touch "$efidir/sealed.tpm"

    # PCR mode (FDE_USE_AUTHORIZED_POLICIES != y*) -> rc 0
    FDE_USE_AUTHORIZED_POLICIES="no"
    run grub_check_sealed_key
    assert_success

    # AP mode without FDE_AUTHORIZED_POLICY -> rc 1
    FDE_USE_AUTHORIZED_POLICIES="yes"
    unset FDE_AUTHORIZED_POLICY
    run grub_check_sealed_key
    assert_failure 1

    # AP mode with policy, but base secret missing -> rc 1
    FDE_AUTHORIZED_POLICY="default"
    tpm_define_authorized_policy_paths "default"
    rm -f "${FDE_AP_SEALED_SECRET}"
    run grub_check_sealed_key
    assert_failure 1

    # AP mode with base secret present
    mkdir -p "$(dirname "${FDE_AP_SEALED_SECRET}")"
    touch "${FDE_AP_SEALED_SECRET}"

    # tpm2key-tool comparison succeeds
    echo 0 > "$MOCK_DIR/tpm2key-tool.rc"
    run grub_check_sealed_key
    assert_success
    assert_mock_called "tpm2key-tool cmp"

    # tpm2key-tool comparison fails
    echo 1 > "$MOCK_DIR/tpm2key-tool.rc"
    run grub_check_sealed_key
    assert_failure 1

    # tpm2key-tool missing fallback -> rc 0
    type() {
        if [ "$1" = "tpm2key-tool" ]; then
            return 1
        fi
        builtin type "$@"
    }
    run grub_check_sealed_key
    assert_success
    unset -f type
}

@test "UT-G07: grub_remove_keyslots removes explicit or detected slots and cleans" {
    # Explicit keyslots
    : > "$MOCK_LOG"
    echo -e "1\n3" > "$MOCK_DIR/fdectl-grub-tpm2.out"
    grub_remove_keyslots "/dev/fake" "1 3"
    assert_mock_called "cryptsetup luksKillSlot -q /dev/fake 1"
    assert_mock_called "cryptsetup luksKillSlot -q /dev/fake 3"
    assert_mock_called "fdectl-grub-tpm2 clean /dev/fake"

    # Empty slots: uses grub_get_keyslots
    : > "$MOCK_LOG"
    echo -e "2\n5" > "$MOCK_DIR/fdectl-grub-tpm2.out"
    grub_remove_keyslots "/dev/fake" ""
    assert_mock_called "cryptsetup luksKillSlot -q /dev/fake 2"
    assert_mock_called "cryptsetup luksKillSlot -q /dev/fake 5"
    assert_mock_called "fdectl-grub-tpm2 clean /dev/fake"
}

@test "UT-G08: grub_rsa_sizes probes supported sizes from shim-install and grub2-protect" {
    local fake_shim="$TEST_ROOT/fake_shim_install"
    export SHIM_INSTALL="$fake_shim"

    # Case 1: shim-install does not support GRUB_TPM2_SRK_ALG -> 2048
    echo '#!/bin/sh' > "$fake_shim"
    run grub_rsa_sizes
    assert_success
    assert_output "2048"

    # Case 2: shim-install supports SRK, grub2-protect supports RSA4096
    echo 'GRUB_TPM2_SRK_ALG' >> "$fake_shim"
    echo 'Usage: grub2-protect [options] ... RSA4096 ...' > "$MOCK_DIR/grub2-protect.out"
    run grub_rsa_sizes
    assert_success
    assert_output "4096 3072 2048"

    # Case 3: shim-install supports SRK, grub2-protect lacks RSA4096
    echo 'Usage: grub2-protect [options] ... RSA2048 ...' > "$MOCK_DIR/grub2-protect.out"
    run grub_rsa_sizes
    assert_success
    assert_output "2048"
}

@test "UT-G09: grub_commit_config runs the shim-install that SHIM_INSTALL names" {
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    local fake="$TEST_ROOT/my-shim-install"
    printf '#!/bin/sh\necho "fake $*" >> "%s"\n' "$TEST_ROOT/fake.log" > "$fake"
    chmod +x "$fake"

    SHIM_INSTALL="$fake" grub_commit_config
    assert_equal "$(cat "$TEST_ROOT/fake.log")" "fake --no-grub-install"
    assert_mock_not_called "shim-install"
}

@test "UT-G10: without SHIM_INSTALL, the script found in PATH is run and inspected" {
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    unset SHIM_INSTALL
    run grub_shim_install
    assert_output "$MOCK_BIN_DIR/shim-install"

    grub_commit_config
    assert_mock_called "shim-install --no-grub-install"

    # The PATH copy has no GRUB_TPM2_SRK_ALG support -> 2048
    run grub_rsa_sizes
    assert_output "2048"
}
