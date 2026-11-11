#!/usr/bin/env bats

load ../helpers/root.bash

setup() {
    load_bats_libs
    setup_root_env
}

teardown() {
    teardown_root_env
}

@test "LK-12: luks_decrypt decrypts volume in-place and handles status file" {
    local img="$TEST_ROOT/dec_root.img"
    local key="$TEST_ROOT/dec.key"
    local wrong_key="$TEST_ROOT/wrong.key"
    echo "correct_recovery_key_data" > "$key"
    echo "wrong_recovery_key_data" > "$wrong_key"

    truncate -s 64M "$img"
    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 -q \
        --key-file "$key" "$img"

    attach_loop_device "$img"
    local loop_dev="$ROOT_LOOP_DEV"

    # 1. Negative test: wrong keyfile propagates status file failure
    run luks_decrypt "$loop_dev" "$wrong_key"
    assert_failure 1
    assert_output --partial "Warning: cryptsetup reencrypt --decrypt indicates failure"
    run cryptsetup isLuks "$loop_dev"
    assert_success

    # 2. Positive test: in-place decryption strips LUKS2 header
    run luks_decrypt "$loop_dev" "$key"
    assert_success

    run cryptsetup isLuks "$loop_dev"
    assert_failure

    # Header backup is removed upon successful completion
    [ ! -f "$FDE_DECRYPT_HEADER" ] || fail "detached header was not cleaned up on success"
}

@test "LK-13: luks_reencrypt reencrypts volume and feeds progress to display_gauge" {
    local img="$TEST_ROOT/reenc_root.img"
    local key="$TEST_ROOT/reenc.key"
    echo "reencrypt_recovery_key_data" > "$key"

    truncate -s 64M "$img"
    cryptsetup luksFormat --type luks2 --pbkdf pbkdf2 --pbkdf-force-iterations 1000 -q \
        --key-file "$key" "$img"

    attach_loop_device "$img"
    local loop_dev="$ROOT_LOOP_DEV"

    local gauge_log="$TEST_ROOT/gauge.log"
    display_gauge() { cat > "$gauge_log"; }

    run luks_reencrypt "$loop_dev" "$key"
    assert_success

    run cryptsetup isLuks "$loop_dev"
    assert_success

    # Verify display_gauge received progress updates ending in 100
    [ -f "$gauge_log" ]
    assert_equal "$(tail -n1 "$gauge_log")" "100"
}
