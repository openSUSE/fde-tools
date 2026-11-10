#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env

    # Mock dialog 'd' function from jeos-firstboot plumbing
    d() {
        while [ $# -gt 0 ]; do
            case "$1" in
            --msgbox|--infobox)
                echo "$2"
                return 0
                ;;
            *)
                shift
                ;;
            esac
        done
        return 0
    }
}

teardown() {
    teardown_fde_env
}

@test "FB-01: firstboot/fde sources its files from FDE_SHAREDIR, FDE_SYSCONFIG, FDE_GRUB_DEFAULTS" {
    local fake="$TEST_ROOT/fake-share"
    mkdir -p "$fake/ui"
    local lib
    for lib in util luks tpm uefi grub2 ui/dialog; do
        echo "LOADED_${lib//\//_}=1" > "$fake/$lib"
    done
    echo 'LOADED_SYSCONFIG=1' > "$TEST_ROOT/fake-sysconfig"
    echo 'LOADED_GRUB_DEFAULTS=1' > "$TEST_ROOT/fake-grub"

    FDE_SHAREDIR="$fake" FDE_SYSCONFIG="$TEST_ROOT/fake-sysconfig" \
        FDE_GRUB_DEFAULTS="$TEST_ROOT/fake-grub"
    . "$REPO/firstboot/fde"

    for lib in util luks tpm uefi grub2 ui_dialog SYSCONFIG GRUB_DEFAULTS; do
        local var="LOADED_$lib"
        assert_equal "${!var}" "1"
    done
}

@test "FB-02: firstboot/fde loads with the repo libraries" {
    # FDE_SHAREDIR, FDE_SYSCONFIG, FDE_GRUB_DEFAULTS come from setup_fde_env
    . "$REPO/firstboot/fde"
    declare -F fde_firstboot fde_systemd_firstboot grub_get_fde_password \
        luks_drop_other_keyslots >/dev/null
}

@test "FB-03: fde_choose_protection user selects pass and tpm" {
    . "$REPO/firstboot/fde"

    tpm_present_and_working() { return 0; }
    uefi_secure_boot_enabled() { return 0; }
    d() { result="pass tpm"; return 0; }

    fde_choose_protection
    assert_equal "$FDE_PROTECTION" "pass tpm"
}

@test "FB-04: fde_choose_protection user cancels dialog returns 1" {
    . "$REPO/firstboot/fde"

    tpm_present_and_working() { return 0; }
    uefi_secure_boot_enabled() { return 0; }
    d() { return 1; }

    run fde_choose_protection
    assert_failure 1
    assert_equal "$FDE_PROTECTION" ""
}

@test "FB-05: fde_choose_protection rejects selection without mandatory pass phrase" {
    . "$REPO/firstboot/fde"

    tpm_present_and_working() { return 0; }
    uefi_secure_boot_enabled() { return 0; }

    local call_count=0
    d() {
        while [ $# -gt 0 ]; do
            case "$1" in
            --checklist)
                call_count=$((call_count + 1))
                if [ "$call_count" -eq 1 ]; then
                    result="tpm" # Invalid: pass is mandatory
                else
                    result="pass tpm"
                fi
                return 0
                ;;
            --msgbox|--infobox)
                echo "$2"
                return 0
                ;;
            *)
                shift
                ;;
            esac
        done
        return 0
    }

    run fde_choose_protection
    assert_success
    assert_output --partial "Pass phrase is mandatory"
}

@test "FB-06: fde_setup_encrypted provisions volume, drops keyslots, and calls fdectl" {
    . "$REPO/firstboot/fde"

    luks_get_underlying_device() { echo "/dev/sda2"; }
    tpm_test() { return 0; }
    luks_verify_password() { return 0; }
    luks_change_password() { result_password="new_recovery_pass"; return 0; }
    luks_drop_other_keyslots() { return 0; }
    luks_reencrypt() { return 0; }

    FDE_PROTECTION="pass tpm"

    # Setup dummy keyfile, crypttab, and dracut config
    local imager_key="$TEST_ROOT/imager.key"
    echo "imager_random_secret" > "$imager_key"
    mkdir -p "$(dirname "$FDE_DRACUT_CONF")"
    touch "$FDE_DRACUT_CONF"
    mkdir -p "$(dirname "$FDE_CRYPTTAB")"
    echo "cr_root /dev/sda2 $imager_key" > "$FDE_CRYPTTAB"
    mkdir -p "$(dirname "$FDE_GRUB_CFG")"

    run fde_setup_encrypted "/dev/mapper/cr_root" "$imager_key" "builtin_pass"
    assert_success

    # Verify fdectl regenerate-key was invoked with passfile
    assert_mock_called "fdectl regenerate-key --passfile"
    assert_mock_called "systemctl enable fde-tpm-enroll.service"
    assert_mock_called "dracut -f"
    assert_mock_called "grub2-mkconfig -o $FDE_GRUB_CFG"

    # Verify imager keyfile and dracut conf were removed
    [ ! -f "$imager_key" ] || fail "imager keyfile was not removed"
    [ ! -f "$FDE_DRACUT_CONF" ] || fail "dracut conf was not removed"
    assert_equal "$(cat "$FDE_CRYPTTAB")" "cr_root /dev/sda2 /.virtual-root.key"
}

@test "FB-07: fde_setup_encrypted with password-only boot calls fde_protect_notpm" {
    . "$REPO/firstboot/fde"

    luks_get_underlying_device() { echo "/dev/sda2"; }
    luks_verify_password() { return 0; }
    luks_change_password() { result_password="new_recovery_pass"; return 0; }
    luks_drop_other_keyslots() { return 0; }
    luks_reencrypt() { return 0; }
    mkdir -p "$(dirname "$FDE_GRUB_CFG")"

    FDE_PROTECTION="pass"
    : > "$MOCK_LOG"

    run fde_setup_encrypted "/dev/mapper/cr_root" "" "builtin_pass"
    assert_success
    assert_mock_not_called "fdectl"
    assert_mock_called "shim-install"
}

@test "FB-08: fde_setup_encrypted falls back to password-only if fdectl regenerate-key fails" {
    . "$REPO/firstboot/fde"

    luks_get_underlying_device() { echo "/dev/sda2"; }
    tpm_test() { return 0; }
    luks_verify_password() { return 0; }
    luks_change_password() { result_password="new_recovery_pass"; return 0; }
    luks_drop_other_keyslots() { return 0; }
    luks_reencrypt() { return 0; }
    mkdir -p "$(dirname "$FDE_GRUB_CFG")"

    FDE_PROTECTION="pass tpm"
    echo 1 > "$MOCK_DIR/fdectl.rc"
    : > "$MOCK_LOG"

    run fde_setup_encrypted "/dev/mapper/cr_root" "" "builtin_pass"
    assert_success
    assert_output --partial "Failed to protect encrypted volume with TPM"
    assert_mock_not_called "systemctl enable fde-tpm-enroll.service"
}

@test "FB-09: fde_setup_encrypted rejects root device that is not a dm device" {
    . "$REPO/firstboot/fde"
    : > "$MOCK_LOG"

    run fde_setup_encrypted "/dev/sda2" "" "pass"
    assert_failure 1
    assert_output --partial "does not look like a dm device"
    assert_mock_not_called "fdectl"
}

@test "FB-10: fde_setup_unencrypted decrypts volume, removes crypttab, and rebuilds initrd" {
    . "$REPO/firstboot/fde"

    luks_get_underlying_device() { echo "/dev/sda2"; }
    luks_decrypt() { return 0; }

    mkdir -p "$(dirname "$FDE_CRYPTTAB")"
    touch "$FDE_CRYPTTAB"

    run fde_setup_unencrypted "/dev/mapper/cr_root" "" "recovery_pass"
    assert_success
    assert_mock_called "dracut --force"
    [ ! -f "$FDE_CRYPTTAB" ] || fail "crypttab was not removed"
}
