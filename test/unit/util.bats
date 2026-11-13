#!/usr/bin/env bats

load ../helpers/common.bash

setup() {
    load_bats_libs
    setup_fde_env
    . "$SHAREDIR/ui/shell"
    . "$SHAREDIR/util"
}

teardown() {
    teardown_fde_env
}

@test "UT-U01: fde_request_recovery_password: opt_password wins over prompt" {
    prompt_called=0
    request_password() {
        prompt_called=1
        result_password="prompt_pw"
    }

    opt_password="cli_password"
    unset __fde_cached_recovery_password
    fde_request_recovery_password
    [ "$?" -eq 0 ]
    assert_equal "$result_password" "cli_password"
    assert_equal "$prompt_called" "0"
}

@test "UT-U02: fde_request_recovery_password: password is cached on second call" {
    prompt_count=0
    request_password() {
        prompt_count=$((prompt_count + 1))
        result_password="prompt_pw_${prompt_count}"
    }

    opt_password=""
    unset __fde_cached_recovery_password

    fde_request_recovery_password
    assert_equal "$result_password" "prompt_pw_1"
    assert_equal "$prompt_count" "1"

    # Second call should return cached password without calling prompt
    fde_request_recovery_password
    assert_equal "$result_password" "prompt_pw_1"
    assert_equal "$prompt_count" "1"
}

@test "UT-U03: fde_request_recovery_password: empty input returns rc 1" {
    request_password() {
        result_password=""
    }

    opt_password=""
    unset __fde_cached_recovery_password

    run fde_request_recovery_password
    assert_failure 1
}

@test "UT-U04: fde_request_recovery_passfile: opt_passfile copied byte-for-byte" {
    local passfile="$TEST_ROOT/passfile.bin"
    local outfile="$TEST_ROOT/outfile.bin"
    printf "raw_secret\x00_data" > "$passfile"

    opt_passfile="$passfile"
    run fde_request_recovery_passfile "$outfile"
    assert_success
    cmp "$passfile" "$outfile"
}

@test "UT-U05: fde_request_recovery_passfile: missing passfile falls back to prompt" {
    local outfile="$TEST_ROOT/outfile.bin"
    opt_passfile="$TEST_ROOT/nonexistent.pass"

    request_password() {
        result_password="fallback_password"
    }
    opt_password=""
    unset __fde_cached_recovery_password

    run fde_request_recovery_passfile "$outfile"
    assert_success
    [ -f "$outfile" ]
    assert_equal "$(cat "$outfile")" "fallback_password"
}

@test "UT-U06: sysconfig_set_variable: existing, commented, missing, and special characters" {
    local cfg="$TEST_ROOT/test_config"
    cat << 'EOF' > "$cfg"
EXISTING="initial"
# COMMENTED="old"
OTHER="keep"
EOF

    # Update existing variable
    sysconfig_set_variable "$cfg" "EXISTING" "updated"
    # Uncomment and update commented variable
    sysconfig_set_variable "$cfg" "COMMENTED" "new_val"
    # Append missing variable
    sysconfig_set_variable "$cfg" "MISSING" "appended"
    # Special characters: |, &, /, \
    local special_val='foo|bar&baz/qux\end'
    sysconfig_set_variable "$cfg" "SPECIAL" "$special_val"

    # Verify file can be sourced and contains expected values
    unset EXISTING COMMENTED OTHER MISSING SPECIAL
    . "$cfg"
    assert_equal "$EXISTING" "updated"
    assert_equal "$COMMENTED" "new_val"
    assert_equal "$OTHER" "keep"
    assert_equal "$MISSING" "appended"
    assert_equal "$SPECIAL" "$special_val"
}

# Read VAR back from a file the way consumers do: by sourcing it.
_source_value() {
    local shell="$1" cfg="$2" var="$3"
    "$shell" -c '. "$1"; eval "printf %s \"\${$2}\""' _ "$cfg" "$var"
}

@test "UT-U06: sysconfig_set_variable: shell-special values round-trip on both write paths" {
    local cfg="$TEST_ROOT/test_config_rt"
    local values=(
        'plain-1234'
        'a"b'
        'x$(touch "$TEST_ROOT/pwned")y'
        'b`touch "$TEST_ROOT/pwned"`q'
        'back\slash\'
        'a|b&c/d'
        "it's"
        '$HOME'
        ''
        'trail '
        "$(printf 'tab\there')"
    )
    local v path shell got
    for v in "${values[@]}"; do
        for path in append sed; do
            if [ "$path" = append ]; then
                : > "$cfg"
            else
                echo 'RT_VAR="old"' > "$cfg"
            fi
            sysconfig_set_variable "$cfg" RT_VAR "$v"
            [ "$(grep -c '^RT_VAR=' "$cfg")" -eq 1 ] ||
                fail "$path: expected exactly one RT_VAR line for [$v]"
            assert_equal "$RT_VAR" "$v"
            for shell in sh bash; do
                got=$(_source_value "$shell" "$cfg" RT_VAR)
                [ "$got" = "$v" ] ||
                    fail "$path/$shell: wrote [$v], read back [$got]: $(cat "$cfg")"
            done
        done
    done
    [ ! -e "$TEST_ROOT/pwned" ] || fail "a value was executed when sourced"
}

@test "UT-U06: sysconfig_set_variable: plain values are written as before" {
    local cfg="$TEST_ROOT/test_config_plain"
    : > "$cfg"
    sysconfig_set_variable "$cfg" PLAIN_VAR "abcd-1234-ef/x.y_z"
    assert_equal "$(cat "$cfg")" 'PLAIN_VAR="abcd-1234-ef/x.y_z"'

    echo '# PLAIN_VAR="old"' > "$cfg"
    sysconfig_set_variable "$cfg" PLAIN_VAR "/etc/fde/root.key"
    assert_equal "$(cat "$cfg")" 'PLAIN_VAR="/etc/fde/root.key"'
}

@test "UT-U06: sysconfig_set_variable: rejects values containing a newline" {
    local cfg="$TEST_ROOT/test_config_nl"
    echo 'NL_VAR="keep"' > "$cfg"
    cp "$cfg" "$cfg.orig"

    run sysconfig_set_variable "$cfg" NL_VAR "$(printf 'a\nb')"
    assert_failure 1
    assert_output --partial "newline in value of NL_VAR"

    run sysconfig_set_variable "$cfg" NL_VAR $'trailing\n'
    assert_failure 1

    run sysconfig_set_variable "$cfg" NEW_NL_VAR $'x\ny'
    assert_failure 1

    cmp "$cfg" "$cfg.orig"
}

@test "UT-U07: sysconfig_set_variable: visible in this shell, not exported" {
    local cfg="$TEST_ROOT/test_config_vis"
    touch "$cfg"

    # Not exported before
    unset VIS_TEST_VAR
    sysconfig_set_variable "$cfg" VIS_TEST_VAR "secret1"
    assert_equal "$VIS_TEST_VAR" "secret1"
    run bash -c 'printf "%s" "${VIS_TEST_VAR-unset}"'
    assert_output "unset"

    # Already exported before: the export flag must be dropped
    export VIS_TEST_VAR=old
    sysconfig_set_variable "$cfg" VIS_TEST_VAR "secret2"
    assert_equal "$VIS_TEST_VAR" "secret2"
    run bash -c 'printf "%s" "${VIS_TEST_VAR-unset}"'
    assert_output "unset"
}

@test "UT-U07: sysconfig_set_variable: rejects invalid variable names" {
    local cfg="$TEST_ROOT/test_config_name"
    echo 'KEEP="1"' > "$cfg"
    cp "$cfg" "$cfg.orig"

    for name in 'BAD NAME' '1ABC' 'A-B' 'A=B' '' 'X;touch pwned' '.*'; do
        run sysconfig_set_variable "$cfg" "$name" "x"
        assert_failure 1
        assert_output --partial "invalid variable name"
    done
    cmp "$cfg" "$cfg.orig"
    [ ! -e pwned ] && [ ! -e "$TEST_ROOT/pwned" ]
}

@test "UT-U07: sysconfig_set_variable: fails and does not set in-memory variable on write error" {
    # 1. Append path failure: destination directory does not exist (fails for both root and non-root)
    local bad_cfg="$TEST_ROOT/nonexistent_dir/cfg"
    unset FAIL_VAR
    run sysconfig_set_variable "$bad_cfg" "FAIL_VAR" "new_val"
    assert_failure 1
    assert_output --partial "sysconfig_set_variable: failed to write FAIL_VAR"
    [ "${FAIL_VAR-unset}" = "unset" ] || fail "FAIL_VAR was unexpectedly set in memory"

    # For unprivileged users, also verify append failure on DAC read-only file
    if [ "$(id -u)" -ne 0 ]; then
        local ro_cfg="$TEST_ROOT/readonly_config"
        touch "$ro_cfg"
        chmod 0444 "$ro_cfg"
        unset RO_VAR
        run sysconfig_set_variable "$ro_cfg" "RO_VAR" "val"
        assert_failure 1
        assert_output --partial "sysconfig_set_variable: failed to write RO_VAR"
        [ "${RO_VAR-unset}" = "unset" ] || fail "RO_VAR was unexpectedly set in memory"
    fi

    # 2. Update path failure: sed fails to update file
    local cfg="$TEST_ROOT/test_cfg"
    echo 'EXISTING_VAR="old"' > "$cfg"
    sed() { return 1; }

    unset EXISTING_VAR
    run sysconfig_set_variable "$cfg" "EXISTING_VAR" "new_val"
    assert_failure 1
    assert_output --partial "sysconfig_set_variable: failed to update EXISTING_VAR"
    [ "${EXISTING_VAR-unset}" = "unset" ] || fail "EXISTING_VAR was unexpectedly set in memory"
}

@test "UT-U08: fde_random_password format matches 4 hex blocks separated by dashes" {
    run fde_random_password
    assert_success
    assert_output --regexp '^[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}$'
}

@test "UT-U08: fde_random_password generates distinct values across consecutive calls" {
    run fde_random_password
    assert_success
    pass1="$output"

    run fde_random_password
    assert_success
    pass2="$output"

    [ "$pass1" != "$pass2" ]
}

@test "UT-U09: fde_make_tempfile fails when tempdir unset; tempdir mode is 0700" {
    # Check mode of created temp directory
    [ -d "$FDE_TEMP_DIR" ]
    mode=$(stat -c %a "$FDE_TEMP_DIR")
    assert_equal "$mode" "700"

    # When FDE_TEMP_DIR is unset, fde_make_tempfile should fail
    saved_tempdir="$FDE_TEMP_DIR"
    unset FDE_TEMP_DIR
    run fde_make_tempfile "testfile"
    assert_failure 1

    FDE_TEMP_DIR="$saved_tempdir"
}
