#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
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
