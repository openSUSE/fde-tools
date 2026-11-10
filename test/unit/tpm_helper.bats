#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env

    export CRYPTTAB="$TEST_ROOT/etc/crypttab"
    export FDE_SYSCONFIG="$TEST_ROOT/etc/sysconfig/fde-tools"
    export GRUB2_DEFAULT="$TEST_ROOT/etc/default/grub"
    export FDECTL="$MOCK_BIN_DIR/fdectl"
}

teardown() {
    teardown_fde_env
}

@test "TH-01: fde-tpm-helper exits silently if crypttab does not exist" {
    rm -f "$CRYPTTAB"
    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default
    assert_success
    assert_output ""
    assert_mock_not_called "fdectl"
}

@test "TH-02: fde-tpm-helper exits silently if sysconfig or fdectl does not exist" {
    touch "$CRYPTTAB"
    export FDE_SYSCONFIG="$TEST_ROOT/missing-sysconfig"
    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default
    assert_success
    assert_output ""
    assert_mock_not_called "fdectl"

    export FDE_SYSCONFIG="$TEST_ROOT/etc/sysconfig/fde-tools"
    export FDECTL="$TEST_ROOT/missing-fdectl"
    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default
    assert_success
    assert_output ""
    assert_mock_not_called "fdectl"
}

@test "TH-03: fde-tpm-helper exits silently if TPM auto-unlock is not configured in grub defaults" {
    touch "$CRYPTTAB"
    echo "" > "$GRUB2_DEFAULT"
    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default
    assert_success
    assert_output ""
    assert_mock_not_called "fdectl"
}

@test "TH-04: fde-tpm-helper prints regenerate-key hint if authorized policy is disabled" {
    touch "$CRYPTTAB"
    echo 'GRUB_TPM2_SEALED_KEY="sealed.tpm"' > "$GRUB2_DEFAULT"
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' > "$FDE_SYSCONFIG"

    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default shim
    assert_success
    assert_output --partial "Bootloader(s) updated and authorized policy disabled."
    assert_output --partial "Please update the sealed key with 'fdectl regenerate-key'."
    assert_output --partial "Updated bootloader(s): kernel-default shim"
    assert_mock_not_called "fdectl"
}

@test "TH-05: fde-tpm-helper prints tpm-authorize hint if auto-update is disabled" {
    touch "$CRYPTTAB"
    echo 'GRUB_TPM2_SEALED_KEY="sealed.tpm"' > "$GRUB2_DEFAULT"
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' > "$FDE_SYSCONFIG"
    echo 'FDE_TPM_AUTO_UPDATE="no"' >> "$FDE_SYSCONFIG"

    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default
    assert_success
    assert_output --partial "Bootloader(s) updated and signature auto-update disabled."
    assert_output --partial "Please update the signature with 'fdectl tpm-authorize'."
    assert_output --partial "Updated bootloader(s): kernel-default"
    assert_mock_not_called "fdectl"
}

@test "TH-06: fde-tpm-helper calls fdectl tpm-authorize when auto-update is enabled" {
    touch "$CRYPTTAB"
    echo 'GRUB_TPM2_SEALED_KEY="sealed.tpm"' > "$GRUB2_DEFAULT"
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' > "$FDE_SYSCONFIG"
    echo 'FDE_TPM_AUTO_UPDATE="yes"' >> "$FDE_SYSCONFIG"
    echo 0 > "$MOCK_DIR/fdectl.rc"

    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default grub2
    assert_success
    assert_output --partial 'Update the signature due to changes in "kernel-default grub2"'
    assert_mock_called "fdectl tpm-authorize"
}

@test "TH-07: fde-tpm-helper reports failure status if fdectl tpm-authorize fails" {
    touch "$CRYPTTAB"
    echo 'GRUB_TPM2_SEALED_KEY="sealed.tpm"' > "$GRUB2_DEFAULT"
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' > "$FDE_SYSCONFIG"
    echo 'FDE_TPM_AUTO_UPDATE="yes"' >> "$FDE_SYSCONFIG"
    echo 1 > "$MOCK_DIR/fdectl.rc"

    run bash "$REPO/rpm-build/fde-tpm-helper" kernel-default
    assert_failure 1
    assert_output --partial 'Update the signature due to changes in "kernel-default"'
    assert_mock_called "fdectl tpm-authorize"
}
