#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
}

teardown() {
    teardown_fde_env
}

@test "CLI-01: fdectl --help, -h, help prints usage on stdout with rc 0" {
    run bash "$REPO/fde.sh" --help
    assert_success
    assert_output --partial "Usage: fdectl [global-options] command [cmd-options]"
    assert_output --partial "Commands:"

    run bash "$REPO/fde.sh" -h
    assert_success
    assert_output --partial "Usage: fdectl [global-options] command [cmd-options]"

    run bash "$REPO/fde.sh" help
    assert_success
    assert_output --partial "Usage: fdectl [global-options] command [cmd-options]"
}

@test "CLI-02: fdectl --version prints version with rc 0" {
    run bash "$REPO/fde.sh" --version
    assert_success
    # The source tree has the __VERSION__ placeholder, while "make dist"
    # substitutes the real version, so compare against fde.sh itself.
    local expected
    expected=$(sed -n 's/^version=//p' "$REPO/fde.sh")
    [ -n "$expected" ] || fail "No version= line found in fde.sh"
    assert_output "$expected"
}

@test "CLI-03: fdectl with no subcommand returns Missing subcommand with rc 1" {
    run bash "$REPO/fde.sh"
    assert_failure 1
    assert_output --partial "Error: Missing subcommand"
    assert_output --partial "Usage: fdectl"
}

@test "CLI-04: fdectl unknown subcommand returns Unsupported command with rc 1" {
    run bash "$REPO/fde.sh" invalid_subcommand_foo
    assert_failure 1
    assert_output --partial 'Error: Unsupported command "invalid_subcommand_foo"'
    assert_output --partial "Usage: fdectl"
}

@test "CLI-05: fdectl with unknown option returns error with rc 1" {
    run bash "$REPO/fde.sh" --bogus-option
    assert_failure 1
    assert_output --partial "unrecognized option '--bogus-option'"
    assert_output --partial "Usage: fdectl"
}

@test "CLI-06: fdectl --bootloader lilo returns Unsupported boot loader with rc 2" {
    run bash "$REPO/fde.sh" --bootloader lilo tpm-present
    assert_failure 2
    assert_output --partial 'Error: Unsupported boot loader "lilo"'
}
