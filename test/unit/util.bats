#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    . "$SHAREDIR/util"
}

teardown() {
    teardown_fde_env
}

@test "UT-U08: fde_random_password format matches 4 hex blocks separated by dashes" {
    run fde_random_password
    assert_success
    assert_output --regexp '^[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}$'
}

@test "UT-U08: fde_random_password generates distinct values across consecutive calls" {
    run fde_random_password
    assert_success
    pass1="$output"

    run fde_random_password
    assert_success
    pass2="$output"

    [ "$pass1" != "$pass2" ]
}
