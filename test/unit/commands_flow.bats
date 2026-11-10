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

# Set up AP mode with an existing policy whose files have known content.
_setup_ap_policy() {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    mkdir -p "$FDE_CONFIG_DIR/default" "$FDE_ESP_DIR/EFI/opensuse"
    echo "OLD-secret-key" > "$FDE_CONFIG_DIR/default/secret-key.pem"
    echo "OLD-authorized-policy" > "$FDE_CONFIG_DIR/default/authorized-policy.tpm"
    echo "OLD-public-key" > "$FDE_CONFIG_DIR/default/public-key.tpm"
    echo "OLD-sealed" > "$FDE_CONFIG_DIR/default/sealed.tpm"
    echo "OLD-esp-sealed" > "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"
}

# Fail unless the policy files still hold their _setup_ap_policy content.
_assert_ap_policy_unchanged() {
    assert_equal "$(cat "$FDE_CONFIG_DIR/default/secret-key.pem")" "OLD-secret-key"
    assert_equal "$(cat "$FDE_CONFIG_DIR/default/authorized-policy.tpm")" "OLD-authorized-policy"
    assert_equal "$(cat "$FDE_CONFIG_DIR/default/public-key.tpm")" "OLD-public-key"
    assert_equal "$(cat "$FDE_CONFIG_DIR/default/sealed.tpm")" "OLD-sealed"
}

# Fail if a staging directory was left in $FDE_CONFIG_DIR.
_assert_no_staging_dir() {
    local left
    left=$(find "$FDE_CONFIG_DIR" -maxdepth 1 -name '.*.new')
    [ -z "$left" ] || fail "staging directory left behind: $left"
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

    # Verify that firstboot password was removed before signing
    local rm_line sign_line
    rm_line=$(grep -n "luksRemoveKey" "$MOCK_LOG" | head -n 1 | cut -d: -f1)
    sign_line=$(grep -n "pcr-oracle.*sign" "$MOCK_LOG" | head -n 1 | cut -d: -f1)
    [ -n "$rm_line" ] || fail "luksRemoveKey not found in mock log"
    [ -n "$sign_line" ] || fail "pcr-oracle sign not found in mock log"
    [ "$rm_line" -lt "$sign_line" ] ||
        fail "luksRemoveKey (line $rm_line) did not run before pcr-oracle sign (line $sign_line)"

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

    [ -f "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm" ] || fail "sealed.tpm not found on ESP"
    local key
    key=$(sed -n 's/^GRUB_TPM2_SEALED_KEY="\(.*\)"/\1/p' "$FDE_GRUB_DEFAULTS")
    [ "$key" = "sealed.tpm" ]
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

@test "CMD-TE08: tpm-enable in AP mode refused if FDE_ENROLL_NEW_KEY is set" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    echo 'FDE_AUTHORIZED_POLICY="default"' >> "$FDE_SYSCONFIG"
    echo "FDE_ENROLL_NEW_KEY=\"$FDE_CONFIG_DIR/root.key\"" >> "$FDE_SYSCONFIG"

    run bash "$REPO/fde.sh" tpm-enable
    assert_failure 1
    assert_output --partial "Bad, there's a secondary key in $FDE_CONFIG_DIR/root.key"
    assert_mock_not_called "luksRemoveKey"
    assert_mock_not_called "pcr-oracle.*sign"
    assert_mock_called "shim-install --no-grub-install"
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

@test "CMD-TD01: tpm-disable with wrong recovery password aborts leaving sealed key intact" {
    echo "wrong_pass" > "$TEST_ROOT/wrong.key"
    mkdir -p "$FDE_ESP_DIR/EFI/opensuse"
    echo "keep_sealed" > "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm"
    echo 'GRUB_TPM2_SEALED_KEY="EFI/opensuse/sealed.tpm"' >> "$FDE_GRUB_DEFAULTS"
    echo 1 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/wrong.key" tpm-disable
    assert_failure 1
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_not_called "shim-install"
    assert_equal "$(cat "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm")" "keep_sealed"

    local key
    key=$(sed -n 's/^GRUB_TPM2_SEALED_KEY="\(.*\)"/\1/p' "$FDE_GRUB_DEFAULTS")
    [ "$key" = "EFI/opensuse/sealed.tpm" ]
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
    _setup_ap_policy
    echo "recovery_pass" > "$TEST_ROOT/rec.key"

    # Mock cryptsetup: when luksAddKey runs, output "Key slot 2 created."
    cat << 'EOF' > "$MOCK_DIR/cryptsetup.sh"
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "luksAddKey" ]; then
        echo "Key slot 2 created."
        exit 0
    fi
done
exit 0
EOF
    chmod +x "$MOCK_DIR/cryptsetup.sh"

    # Mock fdectl-grub-tpm2: starts with slot 1; when slot 2 is added, answers "1 2"
    cat << 'EOF' > "$MOCK_DIR/fdectl-grub-tpm2.sh"
#!/bin/bash
slot_file="$MOCK_DIR/slots_state"
[ -f "$slot_file" ] || echo "1" > "$slot_file"

if [ "$1" = "add" ]; then
    shift
    while [ $# -gt 0 ]; do
        if [ "$1" = "--key-slot" ]; then
            echo "$(cat "$slot_file") $2" > "$slot_file"
            break
        fi
        shift
    done
    exit 0
elif [ "$1" = "list" ]; then
    cat "$slot_file"
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/fdectl-grub-tpm2.sh"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" regenerate-key
    assert_success
    assert_mock_called "cryptsetup.*luksAddKey.* /dev/sda"
    assert_mock_called "fdectl-grub-tpm2 add --key-slot 2 /dev/sda"

    # Verify slot 1 was killed exactly once and new slot 2 was never killed
    assert_mock_called "cryptsetup luksKillSlot -q /dev/sda 1"
    assert_equal "$(grep -c "luksKillSlot.* 1" "$MOCK_LOG")" "1"
    assert_mock_not_called "luksKillSlot.* 2"

    # The new policy and key are in place, the staging directory is gone
    local new_key
    new_key=$(cat "$FDE_CONFIG_DIR/default/secret-key.pem")
    [[ "$new_key" == mock-private-key-* ]] || fail "private key not regenerated: $new_key"
    assert_equal "$(cat "$FDE_CONFIG_DIR/default/authorized-policy.tpm")" "mock-authorized-policy"
    assert_equal "$(cat "$FDE_CONFIG_DIR/default/public-key.tpm")" "mock-public-key"
    [ "$(cat "$FDE_CONFIG_DIR/default/sealed.tpm")" != "OLD-sealed" ] ||
        fail "sealed key not replaced"
    _assert_no_staging_dir
}

@test "CMD-RK02: regenerate-key aborts before altering slots or policy if recovery password fails" {
    _setup_ap_policy
    echo "wrong_pass" > "$TEST_ROOT/wrong.key"
    echo 1 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/wrong.key" regenerate-key
    assert_failure 1
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_not_called "luksAddKey"
    assert_mock_not_called "luksKillSlot"

    # The private key must not be regenerated before the password is
    # verified: tpm-authorize would then sign the old sealed key with a
    # key the TPM does not accept for it.
    assert_mock_not_called "pcr-oracle"
    _assert_ap_policy_unchanged
    _assert_no_staging_dir
}

@test "CMD-RK03: regenerate-key preserves old keyslots if tpm_enable fails" {
    _setup_ap_policy
    echo "recovery_pass" > "$TEST_ROOT/rec.key"

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
exec "$MOCK_DIR/pcr-oracle.default.sh" "$@"
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" regenerate-key
    assert_failure 1
    assert_mock_called "cryptsetup.*luksAddKey.* /dev/sda"
    # It really failed at signing, after the new key was enrolled
    assert_mock_called "pcr-oracle .* sign "
    # Old keyslot must NOT be killed!
    assert_mock_not_called "luksKillSlot"
    # The key the boot loader uses is untouched
    assert_equal "$(cat "$FDE_ESP_DIR/EFI/opensuse/sealed.tpm")" "OLD-esp-sealed"
}

@test "CMD-RK04: regenerate-key leaves policy and old slots untouched if sealing fails" {
    _setup_ap_policy
    echo "recovery_pass" > "$TEST_ROOT/rec.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"
    echo "1" > "$MOCK_DIR/fdectl-grub-tpm2.out"

    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "seal-secret" ]; then
        exit 1
    fi
done
exec "$MOCK_DIR/pcr-oracle.default.sh" "$@"
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" regenerate-key
    assert_failure 1
    assert_output --partial "Failed to seal secondary LUKS key"
    # The new LUKS key was added before sealing; it stays as an unused
    # slot (removed by the next successful regenerate-key)
    assert_mock_called "luksAddKey"
    assert_mock_not_called "luksKillSlot"
    _assert_ap_policy_unchanged
    _assert_no_staging_dir
}

@test "CMD-RK05: regenerate-key leaves policy untouched if adding the LUKS key fails" {
    _setup_ap_policy
    echo "recovery_pass" > "$TEST_ROOT/rec.key"
    echo "1" > "$MOCK_DIR/fdectl-grub-tpm2.out"

    # The recovery password verifies, luksAddKey fails
    cat << 'EOF' > "$MOCK_DIR/cryptsetup.sh"
#!/bin/bash
for arg in "$@"; do
    if [ "$arg" = "luksAddKey" ]; then
        exit 1
    fi
done
exit 0
EOF
    chmod +x "$MOCK_DIR/cryptsetup.sh"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" regenerate-key
    assert_failure 1
    assert_output --partial "Failed to add secondary LUKS key"
    assert_mock_not_called "luksKillSlot"
    _assert_ap_policy_unchanged
    _assert_no_staging_dir
}

@test "CMD-ASK01: add-secondary-key in PCR mode enrolls key and records FDE_ENROLL_NEW_KEY" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="no"' >> "$FDE_SYSCONFIG"
    echo "recovery_pass" > "$TEST_ROOT/rec.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" add-secondary-key
    assert_success
    assert_mock_called "cryptsetup open --test-passphrase.* /dev/sda"
    assert_mock_called "cryptsetup.*luksAddKey.* /dev/sda"
    [ -f "$FDE_CONFIG_DIR/root.key" ] || fail "root.key not created"

    . "$FDE_SYSCONFIG"
    assert_equal "$FDE_ENROLL_NEW_KEY" "$FDE_CONFIG_DIR/root.key"
}

@test "CMD-ASK03: add-secondary-key refused if FDE_ENROLL_NEW_KEY set or keyslot exists" {
    echo "FDE_ENROLL_NEW_KEY=\"$FDE_CONFIG_DIR/root.key\"" >> "$FDE_SYSCONFIG"

    run bash "$REPO/fde.sh" add-secondary-key
    assert_failure 1
    assert_output --partial "already tried to enroll a secondary key"
    assert_mock_not_called "cryptsetup"

    # Now unset FDE_ENROLL_NEW_KEY but simulate existing keyslot
    sed -i '/^FDE_ENROLL_NEW_KEY=/d' "$FDE_SYSCONFIG"
    echo "0" > "$MOCK_DIR/fdectl-grub-tpm2.out"

    run bash "$REPO/fde.sh" add-secondary-key
    assert_failure 1
    assert_output --partial "already enrolled a secondary key"
    assert_mock_not_called "cryptsetup"
}

@test "CMD-ASK02: add-secondary-key in AP mode creates the policy files and records the policy" {
    echo 'FDE_USE_AUTHORIZED_POLICIES="yes"' >> "$FDE_SYSCONFIG"
    sed -i '/^FDE_AUTHORIZED_POLICY=/d' "$FDE_SYSCONFIG"
    echo "recovery_pass" > "$TEST_ROOT/rec.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" add-secondary-key
    assert_success
    assert_mock_called "pcr-oracle .*--rsa-generate-key"
    assert_mock_called "cryptsetup.*luksAddKey.* /dev/sda"

    local dir="$FDE_CONFIG_DIR/authorized-policy"
    [[ "$(cat "$dir/secret-key.pem")" == mock-private-key-* ]]
    assert_equal "$(cat "$dir/authorized-policy.tpm")" "mock-authorized-policy"
    assert_equal "$(cat "$dir/public-key.tpm")" "mock-public-key"
    [ -s "$dir/sealed.tpm" ] || fail "sealed key missing or empty"
    _assert_no_staging_dir

    . "$FDE_SYSCONFIG"
    assert_equal "$FDE_AUTHORIZED_POLICY" "authorized-policy"
}

@test "CMD-RK06: regenerate-key replaces a staging directory left by an interrupted run" {
    _setup_ap_policy
    echo "recovery_pass" > "$TEST_ROOT/rec.key"
    echo 0 > "$MOCK_DIR/cryptsetup.rc"
    echo "1" > "$MOCK_DIR/fdectl-grub-tpm2.out"
    mkdir -p "$FDE_CONFIG_DIR/.default.new"
    echo "stale" > "$FDE_CONFIG_DIR/.default.new/secret-key.pem"
    echo "stale" > "$FDE_CONFIG_DIR/.default.new/leftover"

    run bash "$REPO/fde.sh" --passfile "$TEST_ROOT/rec.key" regenerate-key
    assert_success
    [[ "$(cat "$FDE_CONFIG_DIR/default/secret-key.pem")" == mock-private-key-* ]]
    _assert_no_staging_dir
}

@test "CMD-TP01: tpm-present checks TPM self-test and sealing round-trip" {
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"

    run bash "$REPO/fde.sh" tpm-present
    assert_success
    assert_mock_called "pcr-oracle self-test"
    assert_mock_called "pcr-oracle .* sign "
    assert_mock_called "pcr-oracle .* unseal-secret"

    # Simulate self-test failure
    echo 1 > "$MOCK_DIR/pcr-oracle.rc"
    run bash "$REPO/fde.sh" tpm-present
    assert_failure 1

    # Simulate recovered key mismatch: unseal outputs different data
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
args=("$@")
out=""
action=""
while [ $# -gt 0 ]; do
    case "$1" in
    --output) out="$2"; shift 2;;
    unseal-secret) action="$1"; shift;;
    *) shift;;
    esac
done
if [ "$action" = "unseal-secret" ] && [ -n "$out" ]; then
    echo "corrupted-recovered-key" > "$out"
    exit 0
fi
exec "$MOCK_DIR/pcr-oracle.default.sh" "${args[@]}"
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    run bash "$REPO/fde.sh" tpm-present
    assert_failure 1
    assert_output --partial "Unable to recover original secret"
}

@test "CMD-TI01: tpm-inspect delegates to tpm_inspect and verifies snapshot" {
    # When log dir is missing or has no snapshot, fails
    run bash "$REPO/fde.sh" tpm-inspect
    assert_failure 1
    assert_output --partial "snapshot not available"

    # When snapshot and grub snapshot exist and match current measurements, succeeds
    local snapdir="$TEST_ROOT/snap_build"
    mkdir -p "$snapdir/tpm-snapshot"
    mkdir -p "$FDE_PROCFS/sys/kernel/random"
    echo "test-boot-id" > "$snapdir/tpm-snapshot/boot_id"
    echo "test-boot-id" > "$FDE_PROCFS/sys/kernel/random/boot_id"
    tar Jcf "$FDE_LOG_DIR/tpm-snapshot.tar.xz" -C "$snapdir" tpm-snapshot

    mkdir -p "$FDE_SYSFS/firmware/efi/efivars"
    touch "$FDE_SYSFS/firmware/efi/efivars/GrubPcrSnapshot-7ce323f2-b841-4d30-a0e9-5474a76c9a3f"
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"

    run bash "$REPO/fde.sh" tpm-inspect
    assert_success
    assert_output --partial "Sealed PCR matching the current settings"
}
