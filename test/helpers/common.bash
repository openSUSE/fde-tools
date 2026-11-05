#!/bin/bash
# common.bash - Shared helper functions for fde-tools bats test suite

# Resolve the absolute path to the fde-tools repository root
REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

load_bats_libs() {
    # System bats is used; assertions are provided natively below
    :
}

fail() {
    echo -e "$*" >&2
    return 1
}

assert_success() {
    if [ "$status" -ne 0 ]; then
        fail "Command failed with status $status (expected 0).\nOutput:\n$output"
    fi
}

assert_failure() {
    local expected="${1:-}"
    if [ "$status" -eq 0 ]; then
        fail "Command succeeded (expected non-zero exit status).\nOutput:\n$output"
    fi
    if [ -n "$expected" ] && [ "$status" -ne "$expected" ]; then
        fail "Command exited with status $status (expected $expected).\nOutput:\n$output"
    fi
}

assert_output() {
    if [ "${1:-}" = "--partial" ]; then
        shift
        local expected="$1"
        if [[ "$output" != *"$expected"* ]]; then
            fail "Expected output to contain '$expected'.\nActual output:\n$output"
        fi
    elif [ "${1:-}" = "--regexp" ]; then
        shift
        local pattern="$1"
        if ! [[ "$output" =~ $pattern ]]; then
            fail "Expected output to match regex '$pattern'.\nActual output:\n$output"
        fi
    else
        local expected="$1"
        if [ "$output" != "$expected" ]; then
            fail "Expected output '$expected'.\nActual output:\n$output"
        fi
    fi
}

assert_equal() {
    local actual="$1"
    local expected="$2"
    if [ "$actual" != "$expected" ]; then
        fail "Expected '$expected', got '$actual'"
    fi
}

setup_fde_env() {
    export REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export TEST_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$TEST_ROOT"/{etc/fde,etc/sysconfig,var/log/fde}
    cp "$REPO/sysconfig.fde" "$TEST_ROOT/etc/sysconfig/fde-tools"

    # Only export variables that the code under test really honors.
    #  - SHAREDIR: fde.sh and the command files.
    #  - FDE_CONFIG_DIR, FDE_LOG_DIR: honored by share/tpm and
    #    share/grub2 when sourced directly. fde.sh still overwrites
    #    both unconditionally, so CLI tests do not get them.
    #  - FDE_SYSCONFIG: only used by load_fde_libs below.
    #
    # WARNING: these paths are still hard-coded and NOT redirected:
    #   /etc/sysconfig/fde-tools (fde.sh, fde_set_variable),
    #   /etc/default/grub (grub_set_control, grub_get_fde_password),
    #   /boot/efi, /dev/shm (fde_make_tempdir), /sys, /proc.
    # Do not write tests that reach code touching them until the path
    # refactoring that makes them overridable has landed. Add the
    # matching export here in the same commit as that refactoring.
    export SHAREDIR="$REPO/share"
    export FDE_SYSCONFIG="$TEST_ROOT/etc/sysconfig/fde-tools"
    export FDE_CONFIG_DIR="$TEST_ROOT/etc/fde"
    export FDE_LOG_DIR="$TEST_ROOT/var/log/fde"

    export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
    export MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    mkdir -p "$MOCK_DIR"
    touch "$MOCK_LOG"

    export MOCK_BIN_DIR="$BATS_TEST_TMPDIR/mock-bin"
    mkdir -p "$MOCK_BIN_DIR"
    local mock_commands=(
        cryptsetup pcr-oracle fdectl-grub-tpm2 shim-install grub2-protect
        tpm2key-tool fde-boot-loader mokutil lsblk df dialog logger chroot
    )
    for cmd in "${mock_commands[@]}"; do
        ln -sf "$REPO/test/mocks/bin/stub" "$MOCK_BIN_DIR/$cmd"
    done

    export PATH="$MOCK_BIN_DIR:$PATH"
}

# Undo what setup_fde_env and the sourced libraries left behind.
# Sourcing share/util creates a temp dir under /dev/shm (see
# fde_make_tempdir), and only fdectl's exit trap normally removes it.
teardown_fde_env() {
    if declare -F fde_clean_tempdir >/dev/null; then
        fde_clean_tempdir
    fi
}

load_fde_libs() {
    shopt -s expand_aliases
    . "$SHAREDIR/luks"
    . "$SHAREDIR/uefi"
    . "$FDE_SYSCONFIG"
    . "$SHAREDIR/ui/shell"
    . "$SHAREDIR/util"
    . "$SHAREDIR/tpm"
    . "$SHAREDIR/grub2"
}

assert_mock_called() {
    local pattern="$1"
    if [ ! -f "$MOCK_LOG" ]; then
        fail "MOCK_LOG ($MOCK_LOG) does not exist"
    fi
    if ! grep -q -E -- "$pattern" "$MOCK_LOG"; then
        fail "Expected mock call matching '$pattern' not found in MOCK_LOG. Contents:\n$(cat "$MOCK_LOG")"
    fi
}

assert_mock_not_called() {
    local pattern="$1"
    if [ -f "$MOCK_LOG" ] && grep -q -E -- "$pattern" "$MOCK_LOG"; then
        fail "Mock call matching '$pattern' was unexpectedly found in MOCK_LOG. Contents:\n$(cat "$MOCK_LOG")"
    fi
}

assert_mock_count() {
    local pattern="$1"
    local expected="$2"
    local count=0
    if [ -f "$MOCK_LOG" ]; then
        count=$(grep -c -E -- "$pattern" "$MOCK_LOG" || true)
    fi
    if [ "$count" -ne "$expected" ]; then
        fail "Expected $expected mock calls matching '$pattern', found $count. Contents:\n$(cat "$MOCK_LOG")"
    fi
}
