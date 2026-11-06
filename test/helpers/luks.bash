#!/bin/bash
# luks.bash - Helper functions for LUKS component tests (L2)

load "$BATS_TEST_DIRNAME/../helpers/common.bash"

setup_luks_env() {
    setup_fde_env

    # cryptsetup lives in /usr/sbin, which is often not in a normal
    # user's PATH. Add it here only, not in setup_fde_env: in unit tests a
    # removed mock must mean "tool missing", not "use the real one".
    # The mocks stay first in PATH.
    export PATH="$PATH:/usr/sbin:/sbin"

    # Remove any existing mock cryptsetup stub before locating the real binary
    rm -f "$MOCK_BIN_DIR/cryptsetup"

    # Locate the real cryptsetup binary on PATH (/usr/sbin, /sbin, etc.)
    local real_cryptsetup
    real_cryptsetup=$(command -v cryptsetup 2>/dev/null)
    if [ -z "$real_cryptsetup" ]; then
        skip "cryptsetup is not installed"
    fi

    # Install a wrapper in MOCK_BIN_DIR.
    # Real cryptsetup benchmarks argon2id with 1 GB of memory by default,
    # which triggers the kernel OOM killer (SIGKILL / 137) inside memory-constrained
    # test and CI containers. When argon2id is selected and no explicit memory limit
    # is passed, cap memory cost at 32 MB (32768 KB) to keep runs fast and reliable.
    cat << EOF > "$MOCK_BIN_DIR/cryptsetup"
#!/bin/bash
has_argon=0
has_mem=0
for arg in "\$@"; do
    if [ "\$arg" = "argon2id" ]; then has_argon=1; fi
    if [ "\$arg" = "--pbkdf-memory" ]; then has_mem=1; fi
done
if [ "\$has_argon" = 1 ] && [ "\$has_mem" = 0 ]; then
    exec "$real_cryptsetup" "\$@" --pbkdf-memory 32768
else
    exec "$real_cryptsetup" "\$@"
fi
EOF
    chmod +x "$MOCK_BIN_DIR/cryptsetup"

    # Use the fdectl-grub-tpm2 built in this repo in place of its stub.
    # Replace only this one stub: putting $REPO itself in PATH would also
    # put the other built tools (fde-boot-loader, ...) in front of their
    # mocks, and fde-boot-loader reads the host's EFI variables.
    # If it is not built, the stub stays, so an installed copy in
    # /usr/sbin is never picked up by accident.
    if [ -x "$REPO/fdectl-grub-tpm2" ]; then
        ln -sf "$REPO/fdectl-grub-tpm2" "$MOCK_BIN_DIR/fdectl-grub-tpm2"
    fi

    load_fde_libs
}

# Skip the test unless the repo's fdectl-grub-tpm2 is built.
require_fdectl_grub_tpm2() {
    if [ ! -x "$REPO/fdectl-grub-tpm2" ]; then
        skip "fdectl-grub-tpm2 is not built (run make)"
    fi
}

# Print the value of FIELD (e.g. "PBKDF", "Iterations", "Time cost")
# of keyslot SLOT, as shown by cryptsetup luksDump.
luks_slot_field() {
    local img="$1" slot="$2" field="$3"
    LC_ALL=C cryptsetup luksDump "$img" | awk -v s="  $slot: luks2" -v f="$field" '
        $0 == s { in_slot = 1; next }
        in_slot && (/^  [0-9]+: / || /^[A-Za-z]/) { exit }
        in_slot {
            line = $0
            sub(/^[ \t]+/, "", line)
            if (index(line, f ":") == 1) {
                sub(/^[^:]*:[ \t]*/, "", line)
                print line
                exit
            }
        }'
}

# Print the number of tokens of TYPE in the LUKS2 header.
luks_token_count() {
    local img="$1" type="$2"
    LC_ALL=C cryptsetup luksDump "$img" |
        sed -n '/^Tokens:/,/^Digests:/p' | grep -c ": ${type}\$" || true
}

make_luks_image() {
    local img="$1"
    local pw="${2:-recoverypassword123}"
    local pbkdf="${3:-pbkdf2}"
    local iters=1000
    if [ "$pbkdf" = "argon2id" ]; then
        iters=4
    fi

    truncate -s 32M "$img"
    printf '%s' "$pw" | cryptsetup luksFormat --type luks2 -q \
        --pbkdf "$pbkdf" --pbkdf-force-iterations "$iters" "$img" -
}
