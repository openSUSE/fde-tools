#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    echo 'FDE_DEVS="/dev/sda"' >> "$FDE_SYSCONFIG"
}

teardown() {
    teardown_fde_env
}

@test "CMD-P01: passwd verifies old password, sets new password, and exits 0" {
    echo "current_pass" > "$TEST_ROOT/old.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    # Provide recovery password via passfile and stdin for new password (twice)
    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/old.key" passwd << 'EOF'
new_recovery_pass
new_recovery_pass
EOF
    assert_success
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_called "cryptsetup.*luksChangeKey.* /dev/sda"
}

@test "CMD-P02: passwd aborts before modifying any device if verification fails on second device" {
    sed -i '/^FDE_DEVS=/d' "$FDE_SYSCONFIG"
    echo 'FDE_DEVS="/dev/sda /dev/sdb"' >> "$FDE_SYSCONFIG"
    echo "password" > "$TEST_ROOT/old.key"

    # Mock cryptsetup: succeed on /dev/sda open, fail on /dev/sdb open
    cat << 'EOF' > "$MOCK_DIR/cryptsetup.sh"
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "/dev/sdb" ]; then
        exit 1
    fi
done
exit 0
EOF
    chmod +x "$MOCK_DIR/cryptsetup.sh"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/old.key" passwd << 'EOF'
new_pass
new_pass
EOF
    assert_failure 1
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sdb"
    assert_mock_not_called "luksChangeKey"
}

@test "CMD-P03: passwd aborts if new password prompt is empty" {
    echo "current_pass" > "$TEST_ROOT/old.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/old.key" passwd </dev/null
    assert_failure 1
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_not_called "luksChangeKey"
}

@test "CMD-ASP01: add-secondary-password enrolls random password and commits config" {
    echo "recovery_pass" > "$TEST_ROOT/rec.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" add-secondary-password
    assert_success
    assert_mock_called "cryptsetup.*luksAddKey.* /dev/sda"
    assert_mock_called "shim-install --no-grub-install"

    . "$FDE_GRUB_DEFAULTS"
    [ -n "$GRUB_CRYPTODISK_PASSWORD" ]
}

@test "CMD-ASP02: add-secondary-password aborts if secondary password already set" {
    echo 'GRUB_CRYPTODISK_PASSWORD="already_exists"' > "$FDE_GRUB_DEFAULTS"

    run bash "$REPO/fde.sh" add-secondary-password
    assert_failure 1
    assert_output --partial "You have already defined a firstboot password"
    assert_mock_not_called "cryptsetup"
}

@test "CMD-RSP01: remove-secondary-password drops key and clears bootloader password" {
    echo 'GRUB_CRYPTODISK_PASSWORD="to_be_removed"' > "$FDE_GRUB_DEFAULTS"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" remove-secondary-password
    assert_success
    assert_mock_called "cryptsetup.*luksRemoveKey.* /dev/sda"
    assert_mock_called "shim-install --no-grub-install"

    . "$FDE_GRUB_DEFAULTS"
    [ -z "$GRUB_CRYPTODISK_PASSWORD" ]
}

@test "CMD-RSP02: remove-secondary-password succeeds when no password was configured" {
    echo 'GRUB_DISTRIBUTOR="openSUSE"' > "$FDE_GRUB_DEFAULTS"

    run bash "$REPO/fde.sh" remove-secondary-password
    assert_success
    assert_output --partial "No firstboot password configured"
    assert_mock_not_called "cryptsetup"
}

@test "CMD-RSP03: remove-secondary-password keeps LUKS slot when supplied to regenerate-key" {
    echo 'GRUB_CRYPTODISK_PASSWORD="firstboot_pw"' > "$FDE_GRUB_DEFAULTS"
    echo "firstboot_pw" > "$TEST_ROOT/firstboot.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    load_fde_libs
    . "$SHAREDIR/commands/remove-secondary-password"
    command="regenerate-key"
    opt_password="firstboot_pw"
    remove_secondary_password "/dev/sda"

    assert_mock_not_called "luksRemoveKey"
    local pass
    pass=$(sed -n 's/^GRUB_CRYPTODISK_PASSWORD="\(.*\)"/\1/p' "$FDE_GRUB_DEFAULTS")
    [ -z "$pass" ]
}

@test "CMD-TE01: tpm-enable in AP mode clears firstboot password and authorizes policy" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    echo 'GRUB_CRYPTODISK_PASSWORD="temp_pass"' > "$FDE_GRUB_DEFAULTS"

    mkdir -p "$FDE_CONFIG_DIR/default"
    touch "$FDE_CONFIG_DIR/default/sealed.tpm"
    touch "$FDE_CONFIG_DIR/default/authorized-policy.tpm"
    touch "$FDE_CONFIG_DIR/default/public-key.tpm"
    touch "$FDE_CONFIG_DIR/default/secret-key.pem"

    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" tpm-enable
    assert_success
    assert_mock_called "cryptsetup.*luksRemoveKey.* /dev/sda"
    assert_mock_called "shim-install --no-grub-install"

    local pass
    pass=$(sed -n 's/^GRUB_CRYPTODISK_PASSWORD="\(.*\)"/\1/p' "$FDE_GRUB_DEFAULTS")
    [ -z "$pass" ]
}

@test "CMD-TE02: tpm-enable in AP mode fails without authorized policy" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    sed -i '/^FDE_AUTHORIZED_POLICY=/d' "$FDE_SYSCONFIG"

    run bash "$REPO/fde.sh" tpm-enable
    assert_failure 1
    assert_output --partial "authorized policies requested, but none created yet"
}

@test "CMD-TE03: tpm-enable in AP mode aborts before removing password if load test fails" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    echo 'GRUB_CRYPTODISK_PASSWORD="temp_pass"' > "$FDE_GRUB_DEFAULTS"

    mkdir -p "$FDE_CONFIG_DIR/default"
    touch "$FDE_CONFIG_DIR/default/sealed.tpm"

    # Mock pcr-oracle load-test failing
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "load-test" ]; then
    exit 0
fi
if [ "$1" = "--input" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    run bash "$REPO/fde.sh" tpm-enable
    assert_failure 1
    assert_output --partial "cannot be loaded by this TPM"
    assert_mock_not_called "luksRemoveKey"

    local pass
    pass=$(sed -n 's/^GRUB_CRYPTODISK_PASSWORD="\(.*\)"/\1/p' "$FDE_GRUB_DEFAULTS")
    [ "$pass" = "temp_pass" ]
}

@test "CMD-TE04: tpm-enable with keyfile replaces key and seals under PCR policy" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' >> "$FDE_SYSCONFIG"
    echo "initial_key" > "$TEST_ROOT/compromised.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    run bash "$REPO/fde.sh" --keyfile "$TEST_ROOT/compromised.key" tpm-enable
    assert_success
    assert_mock_called "cryptsetup.*luksChangeKey.* /dev/sda"
    assert_mock_called "shim-install --no-grub-install"
}

@test "CMD-TE05: tpm-enable with FDE_ENROLL_NEW_KEY unsets variable on success" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' >> "$FDE_SYSCONFIG"
    local new_key="$TEST_ROOT/to_enroll.key"
    echo "key_data" > "$new_key"
    echo "FDE_ENROLL_NEW_KEY=\"$new_key\"" >> "$FDE_SYSCONFIG"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    run bash "$REPO/fde.sh" tpm-enable
    assert_success
    [ ! -f "$new_key" ]

    . "$FDE_SYSCONFIG"
    [ -z "$FDE_ENROLL_NEW_KEY" ]
}

@test "CMD-TE06: tpm-enable returns 0 without commit when already enabled" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' >> "$FDE_SYSCONFIG"
    sed -i '/^FDE_ENROLL_NEW_KEY=/d' "$FDE_SYSCONFIG"
    echo 'GRUB_DISTRIBUTOR="openSUSE"' > "$FDE_GRUB_DEFAULTS"

    run bash "$REPO/fde.sh" tpm-enable
    assert_success
    assert_mock_not_called "shim-install"
}

@test "CMD-TE07: tpm-enable removes leftover firstboot password and commits" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' >> "$FDE_SYSCONFIG"
    sed -i '/^FDE_ENROLL_NEW_KEY=/d' "$FDE_SYSCONFIG"
    echo 'GRUB_CRYPTODISK_PASSWORD="leftover"' > "$FDE_GRUB_DEFAULTS"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    run bash "$REPO/fde.sh" tpm-enable
    assert_success
    assert_mock_called "cryptsetup.*luksRemoveKey.* /dev/sda"
    assert_mock_called "shim-install --no-grub-install"

    local pass
    pass=$(sed -n 's/^GRUB_CRYPTODISK_PASSWORD="\(.*\)"/\1/p' "$FDE_GRUB_DEFAULTS")
    [ -z "$pass" ]
}

@test "CMD-TA01: tpm-activate skips activation when key sealed and no firstboot password" {
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    touch "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' >> "$FDE_SYSCONFIG"
    echo 'GRUB_DISTRIBUTOR="openSUSE"' > "$FDE_GRUB_DEFAULTS"

    run bash "$REPO/fde.sh" tpm-activate
    assert_success
    assert_output --partial "LUKS key already sealed. Skip activation."
    assert_mock_not_called "cryptsetup"
}

@test "CMD-TA02: tpm-activate proceeds if firstboot password is still present" {
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    touch "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' >> "$FDE_SYSCONFIG"
    echo 'GRUB_CRYPTODISK_PASSWORD="still_present"' > "$FDE_GRUB_DEFAULTS"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" tpm-activate
    assert_success
    assert_mock_called "cryptsetup.*luksRemoveKey.* /dev/sda"
    assert_mock_called "shim-install --no-grub-install"
}

@test "CMD-TZ01: tpm-authorize fails without configured authorized policy" {
    sed -i '/^FDE_AUTHORIZED_POLICY=/d' "$FDE_SYSCONFIG"

    run bash "$REPO/fde.sh" tpm-authorize
    assert_failure 1
    assert_output --partial "no authorized policy defined"
}

@test "CMD-TZ02: tpm-authorize leaves existing ESP key intact on signing failure" {
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    mkdir -p "$FDE_CONFIG_DIR/default"
    touch "$FDE_CONFIG_DIR/default/secret-key.pem"
    touch "$FDE_CONFIG_DIR/default/sealed.tpm"

    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    echo "original_esp_sealed_key" > "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"

    # Mock pcr-oracle failure during signing
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
exit 1
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    run bash "$REPO/fde.sh" tpm-authorize
    assert_failure 1
    assert_equal "$(cat "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm")" "original_esp_sealed_key"
}

@test "CMD-TD01: tpm-disable verifies recovery password, removes sealed key, and reverts config" {
    echo "rec_pass" > "$TEST_ROOT/rec.key"
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    touch "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" tpm-disable
    assert_success
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_called "shim-install --no-grub-install"
    [ ! -f "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm" ]

    local key
    key=$(sed -n 's/^GRUB_TPM2_SEALED_KEY="\(.*\)"/\1/p' "$FDE_GRUB_DEFAULTS")
    [ -z "$key" ]
}

@test "CMD-TW01: tpm-wipe disables TPM and wipes grub-tpm2 keyslots" {
    echo "rec_pass" > "$TEST_ROOT/rec.key"
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    touch "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"
    echo "1" > "$MOCK_DIR/fdectl-grub-tpm2.out"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" tpm-wipe
    assert_success
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_called "cryptsetup luksKillSlot -q /dev/sda 1"
    assert_mock_called "fdectl-grub-tpm2 clean /dev/sda"
}

@test "CMD-RK01: regenerate-key rolls key, updates sealed secret, and wipes old keyslot" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    echo "recovery_pass" > "$TEST_ROOT/rec.key"

    mkdir -p "$FDE_CONFIG_DIR/default"
    touch "$FDE_CONFIG_DIR/default/secret-key.pem"
    touch "$FDE_CONFIG_DIR/default/authorized-policy.tpm"
    touch "$FDE_CONFIG_DIR/default/public-key.tpm"
    touch "$FDE_CONFIG_DIR/default/sealed.tpm"

    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    # Simulate old keyslot 1
    echo "1" > "$MOCK_DIR/fdectl-grub-tpm2.out"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" regenerate-key
    assert_success
    assert_mock_called "cryptsetup.*luksAddKey.* /dev/sda"
    assert_mock_called "cryptsetup luksKillSlot -q /dev/sda 1"
}

@test "CMD-RK02: regenerate-key aborts before altering slots if recovery password fails" {
    echo "wrong_pass" > "$TEST_ROOT/wrong.key"
    echo 1 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/wrong.key" regenerate-key
    assert_failure 1
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_not_called "luksAddKey"
    assert_mock_not_called "luksKillSlot"
}

@test "CMD-RK03: regenerate-key preserves old keyslots if tpm_enable fails" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    echo "recovery_pass" > "$TEST_ROOT/rec.key"

    mkdir -p "$FDE_CONFIG_DIR/default"
    touch "$FDE_CONFIG_DIR/default/secret-key.pem"
    touch "$FDE_CONFIG_DIR/default/authorized-policy.tpm"
    touch "$FDE_CONFIG_DIR/default/public-key.tpm"
    touch "$FDE_CONFIG_DIR/default/sealed.tpm"

    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"

    # Simulate old keyslot 1
    echo "1" > "$MOCK_DIR/fdectl-grub-tpm2.out"

    # Make pcr-oracle fail only when signing in tpm_authorize inside tpm_enable
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "sign" ]; then
        exit 1
    fi
done
input=""
output=""
while [ $# -gt 0 ]; do
    case "$1" in
    --input) input="$2"; shift 2;;
    --output) output="$2"; shift 2;;
    *) shift;;
    esac
done
if [ -n "$output" ]; then
    if [ -n "$input" ] && [ -f "$input" ]; then
        cp "$input" "$output"
    else
        touch "$output"
    fi
fi
if [ -n "$input" ] && [ -z "$output" ]; then
    echo "sha256"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" regenerate-key
    assert_failure 1
    assert_mock_called "cryptsetup.*luksAddKey.* /dev/sda"
    # Old keyslot must NOT be killed!
    assert_mock_not_called "luksKillSlot"
}
