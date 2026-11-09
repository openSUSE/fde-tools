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

assert_line() {
    if [ "${1:-}" = "--index" ]; then
        shift
        local idx="$1"
        shift
        local expected="$1"
        if [ "${lines[$idx]}" != "$expected" ]; then
            fail "Expected line $idx to be '$expected', got '${lines[$idx]}'. Output:\n$output"
        fi
    elif [ "${1:-}" = "--partial" ]; then
        shift
        local expected="$1"
        for line in "${lines[@]}"; do
            if [[ "$line" == *"$expected"* ]]; then
                return 0
            fi
        done
        fail "No line partially matched '$expected'. Output:\n$output"
    else
        local expected="$1"
        for line in "${lines[@]}"; do
            if [ "$line" = "$expected" ]; then
                return 0
            fi
        done
        fail "No line equal to '$expected'. Output:\n$output"
    fi
}

setup_fde_env() {
    export REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
    export TEST_ROOT="$BATS_TEST_TMPDIR/root"
    mkdir -p "$TEST_ROOT"/{etc/fde,etc/default,etc/sysconfig,var/log/fde,boot/efi/EFI/opensuse,dev/shm,sys,proc}
    cp "$REPO/sysconfig.fde" "$TEST_ROOT/etc/sysconfig/fde-tools"
    touch "$TEST_ROOT/etc/default/grub"
    touch "$TEST_ROOT/boot/efi/EFI/opensuse/shim.efi"

    export SHAREDIR="$REPO/share"
    # firstboot/fde uses its own name (see the comment there)
    export FDE_SHAREDIR="$REPO/share"
    export FDE_SYSCONFIG="$TEST_ROOT/etc/sysconfig/fde-tools"
    export FDE_CONFIG_DIR="$TEST_ROOT/etc/fde"
    export FDE_LOG_DIR="$TEST_ROOT/var/log/fde"
    export FDE_GRUB_DEFAULTS="$TEST_ROOT/etc/default/grub"
    export FDE_ESP_DIR="$TEST_ROOT/boot/efi"
    export FDE_TMP_PARENT="$TEST_ROOT/dev/shm"
    export FDE_SYSFS="$TEST_ROOT/sys"
    export FDE_PROCFS="$TEST_ROOT/proc"

    export MOCK_DIR="$BATS_TEST_TMPDIR/mock"
    export MOCK_LOG="$BATS_TEST_TMPDIR/mock.log"
    mkdir -p "$MOCK_DIR"
    touch "$MOCK_LOG"

    echo "EFI/opensuse/shim.efi" > "$MOCK_DIR/fde-boot-loader.out"

    # Default pcr-oracle behaviour: write the files the real tool writes.
    # Tests that replace pcr-oracle.sh can still hand the calls they do
    # not care about to this handler: exec "$MOCK_DIR/pcr-oracle.default.sh" "$@"
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.default.sh"
#!/bin/bash
if [ -f "$MOCK_DIR/pcr-oracle.err" ]; then
    cat "$MOCK_DIR/pcr-oracle.err" >&2
fi
input=""
output=""
private_key=""
policy=""
public_key=""
generate=""
action=""
while [ $# -gt 0 ]; do
    case "$1" in
    --input) input="$2"; shift 2;;
    --output) output="$2"; shift 2;;
    --private-key) private_key="$2"; shift 2;;
    --authorized-policy) policy="$2"; shift 2;;
    --public-key) public_key="$2"; shift 2;;
    --rsa-generate-key) generate=1; shift;;
    create-authorized-policy|store-public-key|seal-secret|sign) action="$1"; shift;;
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
# A new private key gets distinct content, so tests can tell whether
# the key was regenerated
if [ -n "$generate" ] && [ -n "$private_key" ]; then
    echo "mock-private-key-$(date +%s%N)-$RANDOM" > "$private_key"
fi
if [ "$action" = create-authorized-policy ] && [ -n "$policy" ]; then
    echo "mock-authorized-policy" > "$policy"
fi
if [ "$action" = store-public-key ] && [ -n "$public_key" ]; then
    echo "mock-public-key" > "$public_key"
fi
if [ -n "$input" ] && [ -z "$output" ]; then
    echo "sha256"
fi
if [ -f "$MOCK_DIR/pcr-oracle.rc" ]; then
    exit "$(cat "$MOCK_DIR/pcr-oracle.rc")"
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.default.sh"
    cp "$MOCK_DIR/pcr-oracle.default.sh" "$MOCK_DIR/pcr-oracle.sh"

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
