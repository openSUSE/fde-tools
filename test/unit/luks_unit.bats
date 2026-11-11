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

@test "UT-L06: luks_decrypt refuses to start if existing header file is present" {
    local hdr="$TEST_ROOT/luks-decrypt-header.backup"
    echo "existing_header_from_interrupted_run" > "$hdr"
    export FDE_DECRYPT_HEADER="$hdr"

    run luks_decrypt "/dev/sda2" "$TEST_ROOT/test.key"
    assert_failure 1
    assert_output --partial "A detached LUKS header already exists at"
    assert_output --partial "cryptsetup reencrypt --resume-only --header \"$hdr\" /dev/sda2"

    # Header file must not be deleted
    [ -f "$hdr" ] || fail "existing header file was unexpectedly deleted"
    assert_equal "$(cat "$hdr")" "existing_header_from_interrupted_run"
    assert_mock_not_called "cryptsetup"
}

@test "UT-L07: luks_decrypt refuses to start if ESP is not a separate mounted filesystem" {
    unset FDE_DECRYPT_HEADER
    local unmounted_esp="$TEST_ROOT/unmounted_esp"
    mkdir -p "$unmounted_esp"
    export FDE_ESP_DIR="$unmounted_esp"

    run luks_decrypt "/dev/sda2" "$TEST_ROOT/test.key"
    assert_failure 1
    assert_output --partial "is not mounted as a separate filesystem"
    assert_output --partial "FDE_DECRYPT_HEADER"
    assert_mock_not_called "cryptsetup"
}

@test "UT-L08: luks_decrypt preserves header file and shows resume instructions on failure" {
    local hdr="$TEST_ROOT/luks-decrypt-header.backup"
    rm -f "$hdr"
    export FDE_DECRYPT_HEADER="$hdr"

    # Mock cryptsetup to simulate failure after creating header backup
    cat << 'EOF' > "$MOCK_DIR/cryptsetup.sh"
#!/bin/bash
header=""
while [ $# -gt 0 ]; do
    case "$1" in
    --header) header="$2"; shift 2;;
    *) shift;;
    esac
done
if [ -n "$header" ]; then
    echo "simulated_header_backup" > "$header"
fi
exit 1
EOF
    chmod +x "$MOCK_DIR/cryptsetup.sh"

    run luks_decrypt "/dev/sda2" "$TEST_ROOT/test.key"
    assert_failure 1
    assert_output --partial "Warning: cryptsetup reencrypt --decrypt indicates failure"
    assert_output --partial "The LUKS header is preserved at:"
    assert_output --partial "cryptsetup reencrypt --resume-only --header \"$hdr\" /dev/sda2"

    # Header must be preserved
    [ -f "$hdr" ] || fail "header file was not preserved on failure"
    assert_equal "$(cat "$hdr")" "simulated_header_backup"
}

@test "UT-L09: luks_decrypt removes header file upon successful completion" {
    local hdr="$TEST_ROOT/luks-decrypt-header.backup"
    rm -f "$hdr"
    export FDE_DECRYPT_HEADER="$hdr"

    # Mock cryptsetup to simulate successful decryption
    cat << 'EOF' > "$MOCK_DIR/cryptsetup.sh"
#!/bin/bash
header=""
while [ $# -gt 0 ]; do
    case "$1" in
    --header) header="$2"; shift 2;;
    *) shift;;
    esac
done
if [ -n "$header" ]; then
    echo "simulated_header_backup" > "$header"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/cryptsetup.sh"

    run luks_decrypt "/dev/sda2" "$TEST_ROOT/test.key"
    assert_success

    # Header must be cleanly removed on success
    [ ! -f "$hdr" ] || fail "header file was not cleaned up on success"
}

@test "UT-L10: luks_decrypt accepts mounted separate ESP and places header there" {
    unset FDE_DECRYPT_HEADER
    local esp="$TEST_ROOT/boot/efi"
    mkdir -p "$esp"
    export FDE_ESP_DIR="$esp"

    # Simulate mounted ESP on separate partition /dev/sda1, distinct from root
    echo 0 > "$MOCK_DIR/mountpoint.rc"
    cat << 'EOF' > "$MOCK_DIR/df.sh"
#!/bin/bash
target="${@: -1}"
if [ "$target" = "/" ]; then
    echo "/dev/mapper/cr_root"
else
    echo "/dev/sda1"
fi
EOF
    chmod +x "$MOCK_DIR/df.sh"

    cat << 'EOF' > "$MOCK_DIR/findmnt.sh"
#!/bin/bash
target=""
while [ $# -gt 0 ]; do
    case "$1" in
    --target) target="$2"; shift 2;;
    *) target="$1"; shift;;
    esac
done
if [ "$target" = "/" ]; then
    echo "/dev/mapper/cr_root"
else
    echo "/dev/sda1"
fi
EOF
    chmod +x "$MOCK_DIR/findmnt.sh"

    cat << 'EOF' > "$MOCK_DIR/cryptsetup.sh"
#!/bin/bash
header=""
while [ $# -gt 0 ]; do
    case "$1" in
    --header) header="$2"; shift 2;;
    *) shift;;
    esac
done
if [ -n "$header" ]; then
    echo "$header" > "$MOCK_DIR/captured_header.txt"
    touch "$header"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/cryptsetup.sh"

    run luks_decrypt "/dev/sda2" "$TEST_ROOT/test.key"
    assert_success

    # Header was placed under ESP
    assert_equal "$(cat "$MOCK_DIR/captured_header.txt")" "${esp}/luks-decrypt-header.backup"
    # And cleaned up on success
    [ ! -f "${esp}/luks-decrypt-header.backup" ] || fail "header backup was not removed on success"
}

@test "UT-L10: luks_decrypt refuses if ESP mount source matches LUKS device" {
    unset FDE_DECRYPT_HEADER
    local esp="$TEST_ROOT/boot/efi"
    mkdir -p "$esp"
    export FDE_ESP_DIR="$esp"

    # Mountpoint succeeds, but df reports same source as luks_dev (/dev/sda2)
    echo 0 > "$MOCK_DIR/mountpoint.rc"
    echo "/dev/sda2" > "$MOCK_DIR/df.out"
    echo "/dev/sda2" > "$MOCK_DIR/findmnt.out"

    run luks_decrypt "/dev/sda2" "$TEST_ROOT/test.key"
    assert_failure 1
    assert_output --partial "is not mounted as a separate filesystem"
    assert_mock_not_called "cryptsetup"
}
