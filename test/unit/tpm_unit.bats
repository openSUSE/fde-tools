#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    shopt -s expand_aliases
    load_bats_libs
    setup_fde_env
    . "$SHAREDIR/ui/shell"
    . "$SHAREDIR/util"
    . "$SHAREDIR/grub2"
    . "$SHAREDIR/tpm"
}

teardown() {
    teardown_fde_env
}

@test "UT-T01: tpm_present_and_working checks pcr-oracle self-test" {
    mkdir -p "$FDE_SYSFS/class/tpm"

    # Success case
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"
    run tpm_present_and_working
    assert_success
    assert_mock_called "pcr-oracle self-test"

    # Failure case
    echo 1 > "$MOCK_DIR/pcr-oracle.rc"
    run tpm_present_and_working
    assert_failure 1
}

@test "UT-T02: tpm_get_rsa_key_size respects explicit setting, probes, or defaults to 2048" {
    # Explicit variable set
    unset __fde_rsa_key_size
    FDE_RSA_KEY_SIZE="3072"
    run tpm_get_rsa_key_size
    assert_success
    assert_output "3072"

    # Unset, but pcr-oracle lacks rsa-test action -> 2048
    unset __fde_rsa_key_size
    unset FDE_RSA_KEY_SIZE
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "rsa-test" ]; then
    echo "Unknown action: rsa-test" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    run tpm_get_rsa_key_size
    assert_success
    assert_output "2048"

    # Probes supported sizes and picks highest supported
    unset __fde_rsa_key_size
    grub_rsa_sizes() { echo "4096 3072 2048"; }
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "--rsa-bits" ] && [ "$2" = "3072" ]; then
    exit 0
elif [ "$1" = "--rsa-bits" ] && [ "$2" = "4096" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    run tpm_get_rsa_key_size
    assert_success
    assert_output "3072"

    # All probed sizes fail -> fallback to 2048
    unset __fde_rsa_key_size
    grub_rsa_sizes() { echo "4096 3072"; }
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "--rsa-bits" ]; then
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    run tpm_get_rsa_key_size
    assert_success
    assert_output --partial "2048"
    assert_output --partial "Failed to find a valid RSA key size"
}

@test "UT-T03: tpm_get_ecc_srk_support handles unrecognized option, explicit yes/no, and auto probe" {
    # Unrecognized option in pcr-oracle
    unset __fde_ecc_srk
    echo "unrecognized option '--ecc-srk'" > "$MOCK_DIR/pcr-oracle.err"
    echo 1 > "$MOCK_DIR/pcr-oracle.rc"
    run tpm_get_ecc_srk_support
    assert_success
    assert_output "no"

    # Explicit yes
    rm -f "$MOCK_DIR/pcr-oracle.err" "$MOCK_DIR/pcr-oracle.rc"
    unset __fde_ecc_srk
    FDE_ECC_SRK="yes"
    run tpm_get_ecc_srk_support
    assert_success
    assert_output "yes"

    # Explicit no
    unset __fde_ecc_srk
    FDE_ECC_SRK="no"
    run tpm_get_ecc_srk_support
    assert_success
    assert_output "no"

    # Auto: ecc-test succeeds
    unset __fde_ecc_srk
    FDE_ECC_SRK="auto"
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"
    run tpm_get_ecc_srk_support
    assert_success
    assert_output "yes"

    # Auto: ecc-test fails -> "no"
    unset __fde_ecc_srk
    FDE_ECC_SRK="auto"
    echo 1 > "$MOCK_DIR/pcr-oracle.rc"
    run tpm_get_ecc_srk_support
    assert_success
    assert_output "no"
}

@test "UT-T04: tpm_get_srk_alg parses output from pcr-oracle load-test" {
    local keyfile="$TEST_ROOT/test.key"
    touch "$keyfile"

    unset __fde_srk_alg
    unset __fde_have_load_test
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "load-test" ]; then
    exit 0
fi
if [ "$1" = "--input" ]; then
    echo "RSA2048"
    exit 0
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    run tpm_get_srk_alg "$keyfile"
    assert_success
    assert_output "RSA2048"

    # Failure from pcr-oracle load-test -> rc 1
    unset __fde_srk_alg
    rm -f "$MOCK_DIR/pcr-oracle.sh"
    echo 1 > "$MOCK_DIR/pcr-oracle.rc"
    run tpm_get_srk_alg "$keyfile"
    assert_failure 1

    # Empty output from load-test -> rc 1
    unset __fde_srk_alg
    rm -f "$MOCK_DIR/pcr-oracle.sh"
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"
    echo "" > "$MOCK_DIR/pcr-oracle.out"
    run tpm_get_srk_alg "$keyfile"
    assert_failure 1

    # Missing file returns 1
    unset __fde_srk_alg
    run tpm_get_srk_alg "$TEST_ROOT/missing.key"
    assert_failure 1
}

@test "UT-T05: tpm_seal_key includes ECC and persistent SRK options" {
    local secret="$TEST_ROOT/secret"
    local sealed="$TEST_ROOT/sealed"
    touch "$secret"

    tpm_snapshot() { :; }
    tpm_get_ecc_srk_support() { echo "yes"; }
    FDE_TPM_PERSISTENT_SRK="0x81000001"
    FDE_SEAL_PCR_LIST="0,2,4,7"
    FDE_SEAL_PCR_BANK="sha256"

    tpm_seal_key "$secret" "$sealed"
    assert_mock_called "--ecc-srk"
    assert_mock_called "--persistent-srk 0x81000001"

    # Negative case: no ECC and no persistent SRK
    tpm_get_ecc_srk_support() { echo "no"; }
    unset FDE_TPM_PERSISTENT_SRK
    : > "$MOCK_LOG"
    tpm_seal_key "$secret" "$sealed"
    assert_mock_not_called "--ecc-srk"
    assert_mock_not_called "--persistent-srk"

    # Legacy case: pcr-oracle lacks --target-platform -> --key-format tpm2.0
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "--target-platform" ]; then
    echo "pcr-oracle: unrecognized option '--target-platform'" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    run tpm_platform_parameters
    assert_success
    assert_output "--key-format tpm2.0"
}

@test "UT-T06: tpm_seal_secret removes partial sealed file on failure" {
    local secret="$TEST_ROOT/secret"
    local sealed="$TEST_ROOT/sealed"
    touch "$secret"
    touch "$sealed"

    # Make tpm_seal_key fail
    tpm_seal_key() { return 1; }

    run tpm_seal_secret "$secret" "$sealed" ""
    assert_failure 1
    [ ! -f "$sealed" ]
}

@test "UT-T07: tpm_authorize renames .new on success and cleans up on failure" {
    local priv="$TEST_ROOT/policy.key"
    local sealed="$TEST_ROOT/sealed.base"
    local signed="$TEST_ROOT/sealed.signed"
    touch "$priv" "$sealed"
    echo "original_content" > "$signed"

    # Success case: staging file should be created and moved over signed key
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
while [ $# -gt 0 ]; do
    if [ "$1" = "--output" ]; then
        echo "new_signed_content" > "$2"
        shift 2
    else
        shift
    fi
done
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    run tpm_authorize "$priv" "$sealed" "$signed"
    assert_success
    assert_equal "$(cat "$signed")" "new_signed_content"
    [ ! -f "${signed}.new" ]

    # Failure case: original content should remain and .new removed
    echo "original_preserved" > "$signed"
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
while [ $# -gt 0 ]; do
    if [ "$1" = "--output" ]; then
        echo "partial_broken_data" > "$2"
        shift 2
    else
        shift
    fi
done
exit 1
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    run tpm_authorize "$priv" "$sealed" "$signed"
    assert_failure 1
    assert_equal "$(cat "$signed")" "original_preserved"
    [ ! -f "${signed}.new" ]
}

@test "UT-T08: tpm_create_authorized_policy generates key only when missing or regenerate-key" {
    local key="$TEST_ROOT/policy.key"
    local pol="$TEST_ROOT/policy.pol"

    # Key exists and normal command -> no --rsa-generate-key
    touch "$key"
    command="tpm-enable"
    : > "$MOCK_LOG"
    tpm_create_authorized_policy "$key" "$pol" ""
    assert_mock_not_called "--rsa-generate-key"

    # Key missing -> passes --rsa-generate-key
    rm -f "$key"
    : > "$MOCK_LOG"
    tpm_create_authorized_policy "$key" "$pol" ""
    assert_mock_called "--rsa-generate-key"

    # Key exists but command is regenerate-key -> passes --rsa-generate-key
    touch "$key"
    command="regenerate-key"
    : > "$MOCK_LOG"
    tpm_create_authorized_policy "$key" "$pol" ""
    assert_mock_called "--rsa-generate-key"

    # --rsa-bits only passed when != 2048
    rm -f "$key"
    tpm_get_rsa_key_size() { echo "2048"; }
    : > "$MOCK_LOG"
    tpm_create_authorized_policy "$key" "$pol" ""
    assert_mock_not_called "--rsa-bits"

    rm -f "$key"
    tpm_get_rsa_key_size() { echo "3072"; }
    : > "$MOCK_LOG"
    tpm_create_authorized_policy "$key" "$pol" ""
    assert_mock_called "--rsa-bits 3072"
}

@test "UT-T09: tpm_snapshot skips if log dir missing; creates tar.xz if present" {
    FDE_SNAPSHOT_NAME="test-snapshot"
    mkdir -p "$FDE_PROCFS/sys/kernel/random"
    echo "fake-boot-id-1234" > "$FDE_PROCFS/sys/kernel/random/boot_id"

    # Skip when log dir missing
    rm -rf "$FDE_LOG_DIR"
    run tpm_snapshot
    assert_success
    assert_output --partial "doesn't exist. Skip snapshot creation"

    # Create when log dir present
    mkdir -p "$FDE_LOG_DIR"
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
while [ $# -gt 0 ]; do
    if [ "$1" = "--create-testcase" ]; then
        mkdir -p "$2"
        echo "predicted_data" > "$2/predicted-pcr.txt"
        shift 2
    else
        shift
    fi
done
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"

    tpm_snapshot
    [ -f "$FDE_LOG_DIR/test-snapshot.tar.xz" ]

    local contents
    contents=$(tar tf "$FDE_LOG_DIR/test-snapshot.tar.xz")
    [[ "$contents" == *"test-snapshot/predicted-pcr.txt"* ]] || fail "missing predicted-pcr.txt in snapshot tar"
    [[ "$contents" == *"test-snapshot/boot_id"* ]] || fail "missing boot_id in snapshot tar"
}

@test "UT-T10: tpm_inspect matches snapshot or detects mismatch" {
    FDE_SNAPSHOT_NAME="test-inspect"
    local snapdir="$TEST_ROOT/snap_build"
    mkdir -p "$snapdir/test-inspect"
    mkdir -p "$FDE_PROCFS/sys/kernel/random"
    echo "test-boot-id" > "$snapdir/test-inspect/boot_id"
    echo "test-boot-id" > "$FDE_PROCFS/sys/kernel/random/boot_id"
    tar Jcf "$FDE_LOG_DIR/test-inspect.tar.xz" -C "$snapdir" test-inspect

    mkdir -p "$FDE_SYSFS/firmware/efi/efivars"
    touch "$FDE_SYSFS/firmware/efi/efivars/GrubPcrSnapshot-7ce323f2-b841-4d30-a0e9-5474a76c9a3f"

    # Case 1: Match
    echo 0 > "$MOCK_DIR/pcr-oracle.rc"
    run tpm_inspect
    assert_success
    assert_output --partial "Sealed PCR matching the current settings"

    # Case 2: Mismatch but matching boot ID -> authorized for next boot
    cat << 'EOF' > "$MOCK_DIR/pcr-oracle.sh"
#!/bin/bash
if [ "$1" = "--from" ]; then
    echo "PCR:7 MISMATCH" >&2
    exit 1
fi
exit 0
EOF
    chmod +x "$MOCK_DIR/pcr-oracle.sh"
    run tpm_inspect
    assert_success
    assert_output --partial "Sealed key authorized for the next boot"

    # Case 3: Mismatch and differing boot ID -> lists PCR usage
    echo "different-boot-id" > "$FDE_PROCFS/sys/kernel/random/boot_id"
    run tpm_inspect
    assert_output --partial "PCR mismatch detected"
    assert_output --partial "* PCR 7: [UEFI] Secure Boot Policy"

    # Case 4: Missing snapshot file -> rc 1
    rm -f "$FDE_LOG_DIR/test-inspect.tar.xz"
    run tpm_inspect
    assert_failure 1
    assert_output --partial "snapshot not available"
}

@test "UT-T11: tpm_pcr_usage returns standard descriptions for PCRs 0 to 14" {
    local i
    for i in {0..14}; do
        run tpm_pcr_usage "$i"
        assert_success
        [ -n "$output" ] || fail "empty description for PCR $i"
    done

    run tpm_pcr_usage 0
    assert_success
    assert_output "[UEFI] Core system firmware executable code"

    run tpm_pcr_usage 1
    assert_success
    assert_output "[UEFI] Core system firmware data/host platform configuration"

    run tpm_pcr_usage 4
    assert_success
    assert_output "[UEFI,shim,GRUB2,systemd] Boot loader and additional drivers"

    run tpm_pcr_usage 7
    assert_success
    assert_output "[UEFI] Secure Boot Policy"

    run tpm_pcr_usage 8
    assert_success
    assert_output "[GRUB2] Commands and kernel command line"

    run tpm_pcr_usage 9
    assert_success
    assert_output "[GRUB2] All files read (grub.cfg, kernel, initrd)"

    run tpm_pcr_usage 14
    assert_success
    assert_output "[shim] MOK certificates and hashes"
}

@test "UT-T11: tpm_pcr_usage returns empty string for unknown PCR" {
    run tpm_pcr_usage 99
    assert_success
    assert_output ""
}
