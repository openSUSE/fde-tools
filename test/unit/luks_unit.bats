#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    # Sourcing util provides fde_trace, and luks provides PBKDF iteration checks
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
