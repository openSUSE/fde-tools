#!/usr/bin/env bats

load ../helpers/luks.bash

setup() {
    load_bats_libs
    setup_luks_env
    require_fdectl_grub_tpm2
}

teardown() {
    teardown_fde_env
}

@test "C-T01: fdectl-grub-tpm2 add and list tokens" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "test_pass"

    # Add token for slot 0
    run fdectl-grub-tpm2 add --key-slot 0 "$img"
    assert_success

    # list prints the tokens as JSON: one grub-tpm2 token for keyslot 0
    run fdectl-grub-tpm2 list "$img"
    assert_success
    local compact
    compact=$(printf '%s' "$output" | tr -d ' \n')
    [[ "$compact" == *'"type":"grub-tpm2","keyslots":["0"]'* ]] ||
        fail "no grub-tpm2 token for keyslot 0 in: $output"

    # list --key-only prints the keyslot ids on one line, each followed
    # by a space
    run fdectl-grub-tpm2 list --key-only "$img"
    assert_success
    assert_output "0 "
}

@test "C-T02: fdectl-grub-tpm2 add rejects non-existent slot or duplicate token" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "test_pass"

    # Slot 7 does not exist yet
    run fdectl-grub-tpm2 add --key-slot 7 "$img"
    assert_failure

    # Add slot 0 token
    run fdectl-grub-tpm2 add --key-slot 0 "$img"
    assert_success

    # Duplicate add for slot 0 reports already in token
    run fdectl-grub-tpm2 add --key-slot 0 "$img"
    assert_output --partial "already in token"
}

@test "C-T03: fdectl-grub-tpm2 clean removes grub-tpm2 tokens without keyslots" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "test_pass"

    fdectl-grub-tpm2 add --key-slot 0 "$img"
    assert_equal "$(luks_token_count "$img" grub-tpm2)" "1"

    # Killing the keyslot leaves the token in the header, with no keyslots.
    # list --key-only already prints nothing at this point, so only the
    # header itself can show whether clean did its job.
    local keyfile
    keyfile=$(luks_write_password pass "test_pass")
    cryptsetup luksKillSlot -q --key-file "$keyfile" "$img" 0
    assert_equal "$(luks_token_count "$img" grub-tpm2)" "1"

    run fdectl-grub-tpm2 clean "$img"
    assert_success
    assert_equal "$(luks_token_count "$img" grub-tpm2)" "0"
}

@test "C-T03: fdectl-grub-tpm2 clean keeps tokens with keyslots and tokens of other types" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "test_pass"

    local rec_key sec_key
    rec_key=$(luks_write_password rec "test_pass")
    sec_key="$TEST_ROOT/sec.key"
    luks_generate_random_key "$sec_key"
    cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
        --key-file "$rec_key" "$img" "$sec_key"

    fdectl-grub-tpm2 add --key-slot 0 "$img"
    fdectl-grub-tpm2 add --key-slot 1 "$img"
    echo '{"type":"fde-test-other","keyslots":["1"]}' |
        cryptsetup token import "$img"
    assert_equal "$(luks_token_count "$img" grub-tpm2)" "2"
    assert_equal "$(luks_token_count "$img" fde-test-other)" "1"

    # Empty the slot-1 grub-tpm2 token (and the other token's keyslot)
    cryptsetup luksKillSlot -q --key-file "$rec_key" "$img" 1

    run fdectl-grub-tpm2 clean "$img"
    assert_success

    # Slot-0 grub-tpm2 token kept, emptied one removed, other type kept
    assert_equal "$(luks_token_count "$img" grub-tpm2)" "1"
    assert_equal "$(luks_token_count "$img" fde-test-other)" "1"
    run fdectl-grub-tpm2 list --key-only "$img"
    assert_output "0 "
}
@test "C-T04: fdectl-grub-tpm2 rejects non-LUKS files" {
    local non_luks="$TEST_ROOT/plain.bin"
    echo "not a luks header" > "$non_luks"

    run fdectl-grub-tpm2 list "$non_luks"
    assert_failure
}

@test "C-T05: fdectl-grub-tpm2 list --key-only outputs keyslots" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "test_pass"

    # Add second slot
    local rec_key sec_key
    rec_key=$(luks_write_password rec "test_pass")
    sec_key="$TEST_ROOT/sec.key"
    luks_generate_random_key "$sec_key"
    cryptsetup luksAddKey --pbkdf pbkdf2 --pbkdf-force-iterations 1000 \
        --key-file "$rec_key" "$img" "$sec_key"

    fdectl-grub-tpm2 add --key-slot 0 "$img"
    fdectl-grub-tpm2 add --key-slot 1 "$img"

    run fdectl-grub-tpm2 list --key-only "$img"
    assert_success
    assert_output --partial "0 1"
}

@test "C-T06: libcryptsetup-token-grub-tpm2 token import, dump, and validation" {
    require_token_plugin

    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "test_pass"

    # 1. Valid token import with external token plugin
    run bash -c "echo '{\"type\":\"grub-tpm2\",\"keyslots\":[\"0\"],\"timestamp\":\"2026-11-10T12:00:00Z\"}' | cryptsetup token import --external-tokens-path '$REPO' '$img'"
    assert_success

    # 2. Dump tokens with external plugin outputs custom timestamp
    run cryptsetup luksDump --external-tokens-path "$REPO" "$img"
    assert_success
    assert_output --partial "timestamp:  2026-11-10T12:00:00Z"

    # 3. Invalid JSON is rejected
    run bash -c "echo 'not a valid json' | cryptsetup token import --external-tokens-path '$REPO' '$img'"
    assert_failure

    # 4. JSON with missing type or non-array keyslots is rejected
    run bash -c "echo '{\"keyslots\":[\"0\"]}' | cryptsetup token import --external-tokens-path '$REPO' '$img'"
    assert_failure

    run bash -c "echo '{\"type\":\"grub-tpm2\",\"keyslots\":\"0\"}' | cryptsetup token import --external-tokens-path '$REPO' '$img'"
    assert_failure
}
