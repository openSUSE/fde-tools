#!/usr/bin/env bats

load ../helpers/luks.bash

setup() {
    load_bats_libs
    setup_luks_env
}

teardown() {
    teardown_fde_env
}

@test "LK-00: L2 uses the repo's fdectl-grub-tpm2; other repo tools stay mocked" {
    # fde-boot-loader is built in the repo too, but must never be run
    # here: it reads the host's EFI variables.
    assert_equal "$(command -v fde-boot-loader)" "$MOCK_BIN_DIR/fde-boot-loader"
    assert_equal "$(readlink "$MOCK_BIN_DIR/fde-boot-loader")" \
        "$REPO/test/mocks/bin/stub"

    if [ -x "$REPO/fdectl-grub-tpm2" ]; then
        assert_equal "$(readlink -f "$(command -v fdectl-grub-tpm2)")" \
            "$(readlink -f "$REPO/fdectl-grub-tpm2")"
    else
        assert_equal "$(readlink "$(command -v fdectl-grub-tpm2)")" \
            "$REPO/test/mocks/bin/stub"
    fi
}

@test "LK-01: luks_verify_password returns 0 for matching password and 1 for wrong password" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "test_recovery_password"

    local keyfile
    keyfile=$(luks_write_password pass "test_recovery_password")
    run luks_verify_password "$img" "$keyfile"
    assert_success

    local badkey
    badkey=$(luks_write_password bad "wrong_password")
    run luks_verify_password "$img" "$badkey"
    assert_failure 1
}

@test "LK-02: luks_add_password enrolls secondary password and both passwords unlock" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "initial_password"

    local keyfile
    keyfile=$(luks_write_password orig "initial_password")

    run luks_add_password "$img" "$keyfile" "secondary_password"
    assert_success

    # Verify both passphrases unlock container
    local key_orig key_sec
    key_orig=$(luks_write_password orig "initial_password")
    key_sec=$(luks_write_password sec "secondary_password")

    run luks_verify_password "$img" "$key_orig"
    assert_success

    run luks_verify_password "$img" "$key_sec"
    assert_success
}

@test "LK-03: luks_set_password updates existing password" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "old_password"

    local old_key new_key
    old_key=$(luks_write_password old "old_password")
    new_key=$(luks_write_password new "new_password")

    run luks_set_password "$img" "$old_key" "$new_key"
    assert_success

    # Old password should no longer work
    old_key=$(luks_write_password old "old_password")
    run luks_verify_password "$img" "$old_key"
    assert_failure

    # New password works
    new_key=$(luks_write_password new "new_password")
    run luks_verify_password "$img" "$new_key"
    assert_success
}

@test "LK-04: luks_change_password with keyfile succeeds" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "initial_pw"

    local unlock_keyfile
    unlock_keyfile=$(luks_write_password orig "initial_pw")

    request_new_password() {
        result_password="changed_pw"
    }

    run luks_change_password "$img" "" "$unlock_keyfile"
    assert_success

    local verify_key
    verify_key=$(luks_write_password check "changed_pw")
    run luks_verify_password "$img" "$verify_key"
    assert_success
}

@test "LK-05: luks_add_key uses minimum pbkdf2 iterations and attaches a grub-tpm2 token" {
    require_fdectl_grub_tpm2
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "recovery_pw"

    local rec_key new_key
    rec_key=$(luks_write_password rec "recovery_pw")
    new_key="$TEST_ROOT/random.key"
    luks_generate_random_key "$new_key"

    FDE_LUKS_PBKDF="pbkdf2"
    run luks_add_key "$img" "$rec_key" "$new_key"
    assert_success

    # The new key unlocks exactly one keyslot
    local slot
    slot=$(luks_keyslot_for_keyfile "$img" "$new_key")
    [[ "$slot" =~ ^[0-9]+$ ]] || fail "new key does not unlock one slot: [$slot]"

    # That slot uses pbkdf2 with the minimum iteration count
    assert_equal "$(luks_slot_field "$img" "$slot" PBKDF)" "pbkdf2"
    assert_equal "$(luks_slot_field "$img" "$slot" Iterations)" "1000"

    # A grub-tpm2 token covers that slot
    run fdectl-grub-tpm2 list --key-only "$img"
    assert_success
    [[ " $output " == *" $slot "* ]] ||
        fail "slot $slot not in grub-tpm2 tokens: [$output]"
}

@test "LK-06: luks_set_key replaces existing keyfile" {
    local img="$TEST_ROOT/luks.img"
    make_luks_image "$img" "recovery_pw"

    local rec_key key1 key2
    rec_key=$(luks_write_password rec "recovery_pw")
    key1="$TEST_ROOT/key1.key"
    key2="$TEST_ROOT/key2.key"
    luks_generate_random_key "$key1"
    luks_generate_random_key "$key2"

    # Without a built fdectl-grub-tpm2 the stub answers the token step
    luks_add_key "$img" "$rec_key" "$key1"

    # Replace key1 with key2
    run luks_set_key "$img" "$key1" "$key2"
    assert_success

    # key1 should fail
    run cryptsetup open --test-passphrase --key-file "$key1" "$img"
    assert_failure

    # key2 should succeed
    run cryptsetup open --test-passphrase --key-file "$key2" "$img"
    assert_success
}

@test "LK-07: luks_generate_random_key creates file of exact configured size" {
    local keyfile="$TEST_ROOT/gen.key"
    local keyfile2="$TEST_ROOT/gen2.key"
    FDE_KEY_SIZE_BYTES=32

    luks_generate_random_key "$keyfile"
    [ -f "$keyfile" ]
    assert_equal "$(stat -c %s "$keyfile")" "32"

    # Verify that two generated keys differ
    luks_generate_random_key "$keyfile2"
    assert_equal "$(stat -c %s "$keyfile2")" "32"
    [ "$(cat "$keyfile")" != "$(cat "$keyfile2")" ] || fail "Generated keys are identical"

    # Enroll the generated key and verify it opens the test volume
    local img="$TEST_ROOT/test.luks"
    make_luks_image "$img" "rec_pw"
    printf '%s' "rec_pw" > "$TEST_ROOT/rec.key"
    luks_add_key "$img" "$TEST_ROOT/rec.key" "$keyfile"
    run cryptsetup open --test-passphrase --key-file "$keyfile" "$img"
    assert_success

    FDE_KEY_SIZE_BYTES=64
    luks_generate_random_key "$keyfile"
    assert_equal "$(stat -c %s "$keyfile")" "64"
}

@test "LK-14: luks_add_key with argon2id uses time cost 4" {
    local img="$TEST_ROOT/luks_argon.img"
    make_luks_image "$img" "rec_pw" "argon2id"

    FDE_LUKS_PBKDF="argon2id"
    local rec_key new_key
    rec_key=$(luks_write_password rec "rec_pw")
    new_key="$TEST_ROOT/argon.key"
    luks_generate_random_key "$new_key"

    # Without a built fdectl-grub-tpm2 the stub answers the token step
    run luks_add_key "$img" "$rec_key" "$new_key"
    assert_success

    local slot
    slot=$(luks_keyslot_for_keyfile "$img" "$new_key")
    [[ "$slot" =~ ^[0-9]+$ ]] || fail "new key does not unlock one slot: [$slot]"

    assert_equal "$(luks_slot_field "$img" "$slot" PBKDF)" "argon2id"
    assert_equal "$(luks_slot_field "$img" "$slot" "Time cost")" "4"
}
