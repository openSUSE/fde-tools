#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    . "$SHAREDIR/util"
    . "$SHAREDIR/tpm"
}

teardown() {
    teardown_fde_env
}

@test "UT-T11: tpm_pcr_usage returns standard descriptions for PCRs 0 to 14" {
    run tpm_pcr_usage 0
    assert_success
    assert_output "[UEFI] Core system firmware executable code"

    run tpm_pcr_usage 1
    assert_success
    assert_output "[UEFI] Core system firmware data/host platform configuration"

    run tpm_pcr_usage 4
    assert_success
    assert_output "[UEFI,shim,GRUB2,systemd] Boot loader and additional drivers"

    run tpm_pcr_usage 7
    assert_success
    assert_output "[UEFI] Secure Boot Policy"

    run tpm_pcr_usage 8
    assert_success
    assert_output "[GRUB2] Commands and kernel command line"

    run tpm_pcr_usage 9
    assert_success
    assert_output "[GRUB2] All files read (grub.cfg, kernel, initrd)"

    run tpm_pcr_usage 14
    assert_success
    assert_output "[shim] MOK certificates and hashes"
}

@test "UT-T11: tpm_pcr_usage returns empty string for unknown PCR" {
    run tpm_pcr_usage 99
    assert_success
    assert_output ""
}
