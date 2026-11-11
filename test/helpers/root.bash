#!/bin/bash
# root.bash - Precondition guards and loopback/device-mapper helpers for root tests

load "$BATS_TEST_DIRNAME/../helpers/luks.bash"

require_root() {
    if [ "$(id -u)" -ne 0 ]; then
        skip "Test requires root privileges (id -u == 0)"
    fi
    if [ ! -e /dev/mapper/control ]; then
        skip "Device-mapper control device (/dev/mapper/control) not available"
    fi
    if ! command -v losetup >/dev/null 2>&1; then
        skip "losetup utility is not available"
    fi
}

setup_root_env() {
    require_root
    setup_luks_env

    export ROOT_LOOP_DEVS=()
    export ROOT_DM_NAMES=()
    export ROOT_MOUNT_POINTS=()
}

attach_loop_device() {
    local img="$1"
    ROOT_LOOP_DEV=$(losetup --find --show "$img") || return 1
    ROOT_LOOP_DEVS+=("$ROOT_LOOP_DEV")
}

teardown_root_env() {
    # 1. Unmount any test mounts
    if [ -n "${ROOT_MOUNT_POINTS[*]}" ]; then
        for mnt in "${ROOT_MOUNT_POINTS[@]}"; do
            if mountpoint -q "$mnt" 2>/dev/null; then
                umount -f "$mnt" 2>/dev/null || true
            fi
            rm -rf "$mnt" 2>/dev/null || true
        done
    fi

    # 2. Close any open device-mapper crypt devices
    if [ -n "${ROOT_DM_NAMES[*]}" ]; then
        for dm in "${ROOT_DM_NAMES[@]}"; do
            cryptsetup close "$dm" 2>/dev/null || true
        done
    fi

    # 3. Detach any allocated loop devices
    if [ -n "${ROOT_LOOP_DEVS[*]}" ]; then
        for loop_dev in "${ROOT_LOOP_DEVS[@]}"; do
            losetup -d "$loop_dev" 2>/dev/null || true
        done
    fi

    teardown_fde_env
}
