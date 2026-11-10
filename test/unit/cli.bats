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

@test "CLI-07: fdectl --bootloader systemd-boot tpm-enable reports not yet implemented" {
    echo 'FDE_DEVS="/dev/sda"' >> "$FDE_SYSCONFIG"
    run bash "$REPO/fde.sh" --bootloader systemd-boot tpm-enable
    assert_failure 1
    assert_output --partial "systemd-boot support not yet implemented"
}

@test "CLI-08: fdectl --device /mnt tpm-enable --keyfile /mnt/root.key strips prefix for chroot" {
    run bash "$REPO/fde.sh" --device /mnt tpm-enable --keyfile /mnt/root.key
    assert_success
    assert_mock_called "chroot /mnt fdectl tpm-enable --keyfile /root.key"
}

@test "CLI-09: fdectl --device /mnt tpm-enable without keyfile invokes chroot without keyfile" {
    run bash "$REPO/fde.sh" --device /mnt tpm-enable
    assert_success
    assert_mock_called "chroot /mnt fdectl tpm-enable"
    assert_mock_not_called "--keyfile"
}

@test "CLI-10: fdectl --uefi-boot-dir sets FDE_UEFI_BOOTDIR" {
    mkdir -p "$FDE_ESP_DIR/EFI/custom"
    . "$SHAREDIR/uefi"
    uefi_set_loader "$FDE_ESP_DIR/EFI/custom"
    run uefi_get_current_efidir
    assert_success
    assert_output "$(realpath "$FDE_ESP_DIR/EFI/custom")"
}

@test "CLI-11: fdectl --use-dialog selects dialog UI" {
    echo 'FDE_DEVS="/dev/sda"' >> "$FDE_SYSCONFIG"
    # In passwd command with empty input, display_errorbox calls dialog --msgbox
    run bash "$REPO/fde.sh" --use-dialog passwd </dev/null
    assert_failure 1
    assert_mock_called "dialog .*--msgbox"
}

@test "CLI-12: fdectl fails early if FDE_LUKS_PBKDF is invalid in sysconfig" {
    echo 'FDE_LUKS_PBKDF="scrypt"' >> "$FDE_SYSCONFIG"
    run bash "$REPO/fde.sh" tpm-present
    assert_failure 1
    assert_output --partial "Invalid FDE_LUKS_PBKDF 'scrypt'"
    assert_mock_not_called "cryptsetup"
}

@test "CLI-13: fdectl sorts and deduplicates devices in FDE_DEVS" {
    echo 'FDE_DEVS="/dev/sdb /dev/sda /dev/sda"' >> "$FDE_SYSCONFIG"
    echo "password" > "$TEST_ROOT/pass.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/pass.key" passwd << 'EOF'
newpass
newpass
EOF
    assert_success
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sdb"

    # Verify /dev/sda was called before /dev/sdb in mock log
    local sda_line sdb_line
    sda_line=$(grep -n "cryptsetup open --test-passphrase.* /dev/sda" "$MOCK_LOG" | head -n1 | cut -d: -f1)
    sdb_line=$(grep -n "cryptsetup open --test-passphrase.* /dev/sdb" "$MOCK_LOG" | head -n1 | cut -d: -f1)
    [ "$sda_line" -lt "$sdb_line" ]
}

@test "CLI-14: fdectl auto-detects LUKS root device when FDE_DEVS is empty" {
    sed -i '/^FDE_DEVS=/d' "$FDE_SYSCONFIG"
    # df returns a /dev/mapper path, which is not a block device here
    export FDE_TEST_SKIP_BLKDEV_CHECK=1
    echo "/dev/mapper/cr_root" > "$MOCK_DIR/df.out"
    echo "/dev/sda2 crypto_LUKS" > "$MOCK_DIR/lsblk.out"
    echo "dummy-pass" > "$TEST_ROOT/pass.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/pass.key" passwd << 'EOF'
newpass
newpass
EOF
    assert_success
    assert_mock_called "df --output=source /"
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda2"
}

@test "CLI-15: fdectl merges FDE_EXTRA_DEVS with detected root device" {
    sed -i '/^FDE_DEVS=/d' "$FDE_SYSCONFIG"
    # df returns a /dev/mapper path, which is not a block device here
    export FDE_TEST_SKIP_BLKDEV_CHECK=1
    echo 'FDE_EXTRA_DEVS="/dev/sdb1"' >> "$FDE_SYSCONFIG"
    echo "/dev/mapper/cr_root" > "$MOCK_DIR/df.out"
    echo "/dev/sda2 crypto_LUKS" > "$MOCK_DIR/lsblk.out"
    echo "dummy-pass" > "$TEST_ROOT/pass.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/pass.key" passwd << 'EOF'
newpass
newpass
EOF
    assert_success
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda2"
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sdb1"
}

@test "CLI-16: fdectl reports error when root is not on LUKS" {
    sed -i '/^FDE_DEVS=/d' "$FDE_SYSCONFIG"
    # df returns a /dev/mapper path, which is not a block device here
    export FDE_TEST_SKIP_BLKDEV_CHECK=1
    echo "/dev/mapper/plain_root" > "$MOCK_DIR/df.out"
    echo "/dev/sda1 ext4" > "$MOCK_DIR/lsblk.out"

    # Match PID 1 root inode so chroot error is not triggered
    mkdir -p "$FDE_PROCFS/1"
    rm -rf "$FDE_PROCFS/1/root"
    ln -s / "$FDE_PROCFS/1/root"

    run bash "$REPO/fde.sh" passwd
    assert_failure 1
    assert_output --partial "Cannot find the underlying partition"
    refute_output --partial "Operation not supported in a chroot environment"
}

@test "CLI-17: fdectl detects chroot environment when root partition lookup fails" {
    sed -i '/^FDE_DEVS=/d' "$FDE_SYSCONFIG"
    # df returns a /dev/mapper path, which is not a block device here
    export FDE_TEST_SKIP_BLKDEV_CHECK=1
    echo "/dev/mapper/plain_root" > "$MOCK_DIR/df.out"
    echo "" > "$MOCK_DIR/lsblk.out"

    # Create dummy inode for PID 1 root that differs from host /
    mkdir -p "$FDE_PROCFS/1/root"

    run bash "$REPO/fde.sh" passwd
    assert_failure 1
    assert_output --partial "Cannot find the underlying partition"
    assert_output --partial "Operation not supported in a chroot environment"
}

@test "CLI-18: fdectl commands not requiring devices bypass device detection" {
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"

    # 1. tpm-present
    run bash "$REPO/fde.sh" tpm-present
    assert_success
    assert_mock_not_called "^df "
    assert_mock_not_called "^lsblk "

    # 2. tpm-authorize
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    mkdir -p "$FDE_CONFIG_DIR/default"
    touch "$FDE_CONFIG_DIR/default/sealed.tpm"
    touch "$FDE_CONFIG_DIR/default/secret-key.pem"
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    touch "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"

    run bash "$REPO/fde.sh" tpm-authorize
    assert_success
    assert_mock_not_called "^df "
    assert_mock_not_called "^lsblk "

    # 3. tpm-inspect
    local snapdir="$TEST_ROOT/snap_build"
    mkdir -p "$snapdir/tpm-snapshot"
    mkdir -p "$FDE_PROCFS/sys/kernel/random"
    echo "test-boot-id" > "$snapdir/tpm-snapshot/boot_id"
    echo "test-boot-id" > "$FDE_PROCFS/sys/kernel/random/boot_id"
    tar Jcf "$FDE_LOG_DIR/tpm-snapshot.tar.xz" -C "$snapdir" tpm-snapshot
    mkdir -p "$FDE_SYSFS/firmware/efi/efivars"
    touch "$FDE_SYSFS/firmware/efi/efivars/GrubPcrSnapshot-7ce323f2-b841-4d30-a0e9-5474a76c9a3f"

    run bash "$REPO/fde.sh" tpm-inspect
    assert_success
    assert_mock_not_called "^df "
    assert_mock_not_called "^lsblk "
}

@test "CLI-19: fdectl cleans up temporary directory on exit and signals" {
    # Case 1: Check cleanup on normal exit
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"
    run bash "$REPO/fde.sh" tpm-present
    assert_success
    [ "$(find "$FDE_TMP_PARENT" -maxdepth 1 -name 'fde.*' | wc -l)" -eq 0 ]

    # Case 2: Check cleanup on command error exit (after util is sourced and tempfile created)
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
exit 1
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    run bash "$REPO/fde.sh" tpm-present
    assert_failure 1
    [ "$(find "$FDE_TMP_PARENT" -maxdepth 1 -name 'fde.*' | wc -l)" -eq 0 ]

    # Case 3: Check cleanup on SIGTERM and that execution halts immediately
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "self-test" ]; then
    sleep 2
    exit 0
fi
echo "$@" >> "$MOCK_DIR/post_signal_calls.log"
exec "$MOCK_DIR/pcr-oracle.default.sh" "$@"
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    rm -f "$MOCK_DIR/post_signal_calls.log"

    bash "$REPO/fde.sh" tpm-present &
    local fde_pid=$!

    # Wait up to 1 second for fde.sh to create its tempdir
    local waited=0
    while [ "$(find "$FDE_TMP_PARENT" -maxdepth 1 -name 'fde.*' | wc -l)" -eq 0 ] && [ "$waited" -lt 10 ]; do
        sleep 0.1
        waited=$((waited + 1))
    done

    # Verify tempdir existed during execution
    [ "$(find "$FDE_TMP_PARENT" -maxdepth 1 -name 'fde.*' | wc -l)" -gt 0 ] ||
        fail "tempdir was not created before signal"

    kill -TERM "$fde_pid" 2>/dev/null || true
    wait "$fde_pid" 2>/dev/null || true

    # Verify tempdir was cleaned up by the trap
    [ "$(find "$FDE_TMP_PARENT" -maxdepth 1 -name 'fde.*' | wc -l)" -eq 0 ] ||
        fail "tempdir was not cleaned up on SIGTERM"

    # Verify that fdectl stopped and did not continue running subsequent commands
    [ ! -f "$MOCK_DIR/post_signal_calls.log" ] ||
        fail "Commands continued running after SIGTERM: $(cat "$MOCK_DIR/post_signal_calls.log")"
}

@test "CLI-20: fdectl preserves passwords with spaces, quotes, and metacharacters" {
    echo 'FDE_DEVS="/dev/sda"' >> "$FDE_SYSCONFIG"

    # Mock cryptsetup to capture the exact keyfile contents passed to it
    cat << 'EOF' > "$MOCK_DIR/cryptsetup.sh"
#!/bin/bash
keyfile=""
while [ $# -gt 0 ]; do
    if [ "$1" = "--key-file" ]; then
        keyfile="$2"
        shift 2
        continue
    fi
    shift
done
if [ -n "$keyfile" ] && [ -f "$keyfile" ]; then
    cp "$keyfile" "$MOCK_DIR/captured.key"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/cryptsetup.sh"

    local pwned_marker="$TEST_ROOT/pwned"
    rm -f "$pwned_marker"
    local complex_pw="a  b * \$(touch \"$pwned_marker\")"

    run bash "$REPO/fde.sh" --password "$complex_pw" passwd << 'EOF'
newpass
newpass
EOF
    assert_success

    # The command substitution must NOT have executed
    [ ! -f "$pwned_marker" ] || fail "Command injection occurred: $pwned_marker was created"

    # The exact bytes, including consecutive spaces and literal '*', must reach cryptsetup
    [ -f "$MOCK_DIR/captured.key" ] || fail "No keyfile reached cryptsetup"
    assert_equal "$(cat "$MOCK_DIR/captured.key")" "$complex_pw"
}

@test "CLI-21: fdectl refuses a root source that is not a block device" {
    sed -i '/^FDE_DEVS=/d' "$FDE_SYSCONFIG"
    echo "/not/a/blockdev" > "$MOCK_DIR/df.out"

    run bash "$REPO/fde.sh" passwd
    assert_failure 2
    assert_output --partial "Unable to determine partition to operate on"
    assert_mock_not_called "lsblk"
    assert_mock_not_called "cryptsetup"
}

@test "CLI-22: FDE_SYSFS alone does not skip the block device check" {
    sed -i '/^FDE_DEVS=/d' "$FDE_SYSCONFIG"
    echo "/not/a/blockdev" > "$MOCK_DIR/df.out"
    export FDE_SYSFS=/sys
    unset FDE_TEST_SKIP_BLKDEV_CHECK

    run bash "$REPO/fde.sh" passwd
    assert_failure 2
    assert_output --partial "Unable to determine partition to operate on"
}

@test "CLI-23: fdectl fails clearly when the sysconfig file is missing" {
    rm -f "$FDE_SYSCONFIG"
    run bash "$REPO/fde.sh" tpm-present
    assert_failure 1
    assert_output --partial "cannot read configuration file $FDE_SYSCONFIG"
    [[ "$output" != *"Invalid FDE_LUKS_PBKDF"* ]] || fail "misleading PBKDF error shown"
    assert_mock_not_called "pcr-oracle"
}

@test "CLI-24: fdectl refuses a sysconfig file with a syntax error" {
    # unclosed quote
    echo 'FDE_SEAL_PCR_LIST="0,2,4' >> "$FDE_SYSCONFIG"
    run bash "$REPO/fde.sh" tpm-present
    assert_failure 1
    assert_output --partial "failed to load configuration file $FDE_SYSCONFIG"
    assert_mock_not_called "pcr-oracle"
}

@test "CLI-25: fdectl refuses an unreadable sysconfig file" {
    [ "$(id -u)" -ne 0 ] || skip "root can read any file"
    chmod 000 "$FDE_SYSCONFIG"
    run bash "$REPO/fde.sh" tpm-present
    assert_failure 1
    assert_output --partial "cannot read configuration file"
}

@test "CLI-26: --help and --version work without a sysconfig file" {
    rm -f "$FDE_SYSCONFIG"
    run bash "$REPO/fde.sh" --help
    assert_success
    run bash "$REPO/fde.sh" --version
    assert_success
}
