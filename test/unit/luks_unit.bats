#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    # Sourcing util provides fde_trace, and luks provides PBKDF iteration checks
    . "$SHAREDIR/ui/shell"
    . "$SHAREDIR/util"
    . "$SHAREDIR/luks"
}

teardown() {
    teardown_fde_env
}

@test "UT-L01: luks_get_minimum_pbkdf_iterations with pbkdf2 returns 1000" {
    FDE_LUKS_PBKDF="pbkdf2"
    run luks_get_minimum_pbkdf_iterations
    assert_success
    assert_output "1000"

    run luks_verify_config_pbkdf
    assert_success
}

@test "UT-L01: luks_get_minimum_pbkdf_iterations with argon2id returns 4" {
    FDE_LUKS_PBKDF="argon2id"
    run luks_get_minimum_pbkdf_iterations
    assert_success
    assert_output "4"

    run luks_verify_config_pbkdf
    assert_success
}

@test "UT-L01: luks_get_minimum_pbkdf_iterations with invalid pbkdf returns rc 1" {
    FDE_LUKS_PBKDF="scrypt"
    run luks_get_minimum_pbkdf_iterations
    assert_failure 1
    assert_output --partial "Invalid FDE_LUKS_PBKDF 'scrypt'"

    run luks_verify_config_pbkdf
    assert_failure 1

    FDE_LUKS_PBKDF=""
    run luks_get_minimum_pbkdf_iterations
    assert_failure 1
}

@test "UT-L02: luks_dm_name_for_device resolves /dev/mapper names" {
    run luks_dm_name_for_device "/dev/mapper/cr_root"
    assert_success
    assert_output "cr_root"

    run luks_dm_name_for_device "/dev/mapper/system-home"
    assert_success
    assert_output "system-home"
}

@test "UT-L03: luks_get_volume_for_fsdev parses multi-PV lsblk output" {
    cp "$REPO/test/fixtures/lsblk.lvm-on-luks.txt" "$MOCK_DIR/lsblk.out"

    run luks_get_volume_for_fsdev "/dev/mapper/system-root"
    assert_success
    # Inverted by tac: /dev/sdb2 then /dev/sda2
    assert_line --index 0 "/dev/sdb2"
    assert_line --index 1 "/dev/sda2"
}

@test "UT-L04: luks_list_keyslots parses luksDump fixtures for LUKS2 and LUKS1" {
    # LUKS2 fixture with keyslots 0, 1, 10, 31
    cp "$REPO/test/fixtures/luksDump.luks2-tokens.txt" "$MOCK_DIR/cryptsetup.out"
    run luks_list_keyslots "/dev/dummy"
    assert_success
    assert_line --index 0 "0"
    assert_line --index 1 "1"
    assert_line --index 2 "10"
    assert_line --index 3 "31"

    # LUKS1 fixture has no : luks2 slots
    cp "$REPO/test/fixtures/luksDump.luks1.txt" "$MOCK_DIR/cryptsetup.out"
    run luks_list_keyslots "/dev/dummy"
    assert_success
    assert_output ""
}

@test "UT-L05: luks_keyslot_for_keyfile parses Key slot N unlocked" {
    echo "Key slot 3 unlocked." > "$MOCK_DIR/cryptsetup.out"
    run luks_keyslot_for_keyfile "/dev/dummy" "$TEST_ROOT/test.key"
    assert_success
    assert_output "3"

    echo "Key slot 7 unlocked." > "$MOCK_DIR/cryptsetup.out"
    run luks_keyslot_for_keyfile "/dev/dummy" "$TEST_ROOT/test.key"
    assert_success
    assert_output "7"
}
