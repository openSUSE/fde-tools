#!/usr/bin/env bats

load ../helpers/luks.bash

setup() {
    load_bats_libs
    setup_luks_env
    # Ensure function calls in share/luks resolve to bootloader_get_keyslots
    unalias bootloader_get_keyslots 2>/dev/null || true
    bootloader_get_keyslots() { grub_get_keyslots "$@"; }
}

teardown() {
    teardown_fde_env
}

@test "LK-08: luks_drop_pass and luks_drop_key kill only target keyslot" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "recovery_pass"

    local rec_key sec_key
    rec_key=$(luks_write_password rec "recovery_pass")
    luks_add_password "$img" "$rec_key" "secondary_pass"

    # Drop secondary password
    run luks_drop_pass "$img" "secondary_pass"
    assert_success

    # Secondary password should be killed
    sec_key=$(luks_write_password sec "secondary_pass")
    run luks_verify_password "$img" "$sec_key"
    assert_failure

    # Recovery password still unlocks
    rec_key=$(luks_write_password rec "recovery_pass")
    run luks_verify_password "$img" "$rec_key"
    assert_success
}

@test "LK-09: luks_drop_other_keyslots preserves recovery slot and TPM slot, drops orphan" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "recovery_pass"

    local rec_key
    rec_key=$(luks_write_password rec "recovery_pass")

    # Add slot 1 (TPM slot) and slot 2 (orphan slot)
    local tpm_key orphan_key
    tpm_key="$TEST_ROOT/tpm.key"
    orphan_key="$TEST_ROOT/orphan.key"
    luks_generate_random_key "$tpm_key"
    luks_generate_random_key "$orphan_key"

    luks_add_key "$img" "$rec_key" "$tpm_key"
    local tpm_slot
    tpm_slot=$(luks_keyslot_for_keyfile "$img" "$tpm_key")

    luks_add_key "$img" "$rec_key" "$orphan_key"
    local orphan_slot
    orphan_slot=$(luks_keyslot_for_keyfile "$img" "$orphan_key")

    # Mock bootloader_get_keyslots to protect tpm_slot
    unalias bootloader_get_keyslots 2>/dev/null || true
    bootloader_get_keyslots() { echo "$tpm_slot"; return 0; }

    rec_key=$(luks_write_password rec "recovery_pass")
    run luks_drop_other_keyslots "$img" "$rec_key"
    assert_success

    # Recovery key and TPM key should still unlock
    rec_key=$(luks_write_password rec "recovery_pass")
    run luks_verify_password "$img" "$rec_key"
    assert_success

    run cryptsetup open --test-passphrase --key-file "$tpm_key" "$img"
    assert_success

    # Orphan slot should be killed
    run cryptsetup open --test-passphrase --key-file "$orphan_key" "$img"
    assert_failure
}

@test "LK-10: luks_drop_other_keyslots aborts if recovery keyfile matches multiple slots" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "same_pass"

    local keyfile
    keyfile=$(luks_write_password pass "same_pass")

    # Mock luks_keyslot_for_keyfile returning multiple slots
    luks_keyslot_for_keyfile() {
        echo "0"
        echo "1"
    }

    run luks_drop_other_keyslots "$img" "$keyfile"
    assert_failure 1
    assert_output --partial "Key file unlocks several slots"
}

@test "LK-11: luks_drop_other_keyslots aborts without killing slots if bootloader query fails" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "recovery_pass"

    local rec_key sec_key
    rec_key=$(luks_write_password rec "recovery_pass")
    luks_add_password "$img" "$rec_key" "secondary_pass"

    # Fail bootloader query
    unalias bootloader_get_keyslots 2>/dev/null || true
    bootloader_get_keyslots() { return 1; }

    rec_key=$(luks_write_password rec "recovery_pass")
    run luks_drop_other_keyslots "$img" "$rec_key"
    assert_failure 1

    # Secondary slot must still be intact
    sec_key=$(luks_write_password sec "secondary_pass")
    run luks_verify_password "$img" "$sec_key"
    assert_success
}
