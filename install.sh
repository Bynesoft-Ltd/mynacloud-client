#!/usr/bin/env bash
# =============================================================================
# install.sh — put tee-claude and its two helper programs on this machine.
#
# It copies four files, makes a symlink, creates ~/.tee-claude with mode 700 and
# (only if you do not already have one) seeds a policy from the example. It touches
# nothing outside your home directory and does not need root. Read it — it is short
# on purpose.
#
# TWO MODES.
#   next to the files   — installs what is beside it. No network at all.
#   on its own          — fetches the release TARBALL and its SHA256SUMS and verifies
#                         the checksum before unpacking anything, so `curl -O` this one
#                         file and run it. That is the same discipline `tee-claude
#                         --update` uses, and it is why this is not a `curl | bash`:
#                         piping straight into a shell means the thing you audited and
#                         the thing that ran are different fetches. Download, read, run.
# =============================================================================
set -euo pipefail

# Piped (curl | bash) there IS no script file: BASH_SOURCE is unset, and under `set -u`
# this line aborted the installer before it printed anything. Empty SRC means "no files
# beside me", which is exactly right — it takes the verified-download path below.
if [ -n "${BASH_SOURCE[0]:-}" ] && [ "${BASH_SOURCE[0]}" != "bash" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SRC="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    SRC=""
fi
HOME_DIR="${TEE_CLAUDE_HOME:-$HOME/.local/share/mynacloud-client}"
BIN_DIR="${TEE_CLAUDE_BINDIR:-$HOME/.local/bin}"
CFG_DIR="${TEE_CLAUDE_CONFIG_DIR:-$HOME/.tee-claude}"

say()  { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  FATAL: %s\n' "$*" >&2; exit 1; }

# EVERYTHING BELOW RUNS ONLY IF THE WHOLE FILE ARRIVED.
#
# `curl | bash` feeds the shell a stream: if the connection drops mid-transfer, bash
# executes the truncated prefix — a half-finished install with no error. Wrapping the body
# in a function and calling it on the very last line makes a partial download a no-op,
# because the call is the last thing to arrive. This is the one real hazard of piping that
# is not a matter of trust, and it costs two lines.
main() {
echo
echo "Installing the mynacloud client"
echo

# ---- dependencies ----------------------------------------------------------
missing=()
for tool in bash python3 curl openssl; do
    command -v "$tool" >/dev/null 2>&1 || missing+=("$tool")
done
if ! command -v dig >/dev/null 2>&1 && ! command -v host >/dev/null 2>&1 \
   && ! command -v nslookup >/dev/null 2>&1; then
    missing+=("dig (or host, or nslookup)")
fi
if ((${#missing[@]})); then
    echo "  Missing required tools: ${missing[*]}"
    echo
    echo "    Debian/Ubuntu:  sudo apt install python3 curl openssl dnsutils"
    echo "    macOS:          these ship with the system; 'dig' comes with"
    echo "                    bind (brew install bind) if it is absent"
    die "install the tools above and re-run this script"
fi

if ! command -v claude >/dev/null 2>&1; then
    warn "'claude' is not on your PATH. tee-claude verifies the endpoint and then"
    warn "launches Claude Code, so install it before your first session:"
    warn "    npm install -g @anthropic-ai/claude-code"
fi

# ---- files: local beside us, or a verified release download ----------------
REPO_SLUG="${MYNACLOUD_REPO:-Bynesoft-Ltd/mynacloud-client}"
NEED=(tee-claude websearch-mcp.py no-attachment-hook.py policy.example.json)

have_all_local=1
for f in "${NEED[@]}"; do [[ -f "$SRC/$f" ]] || have_all_local=0; done

if (( ! have_all_local )); then
    # sha256sum on Linux, shasum -a 256 on macOS. Refuse rather than skip: an unverified
    # tarball is the one thing this installer must not unpack.
    if command -v sha256sum >/dev/null 2>&1;  then SHA() { sha256sum "$1" | awk '{print $1}'; }
    elif command -v shasum >/dev/null 2>&1;   then SHA() { shasum -a 256 "$1" | awk '{print $1}'; }
    else die "need sha256sum or shasum to verify the download"; fi

    VERSION="${MYNACLOUD_VERSION:-}"
    if [[ -z "$VERSION" ]]; then
        say "resolving the latest release of $REPO_SLUG"
        VERSION="$(curl -fsSL "https://api.github.com/repos/$REPO_SLUG/releases/latest" \
                   | python3 -c 'import json,sys; print(json.load(sys.stdin).get("tag_name",""))' 2>/dev/null || true)"
        [[ -n "$VERSION" ]] || die "could not resolve the latest release; pass MYNACLOUD_VERSION=vX.Y.Z"
    fi
    say "version  $VERSION"

    TMP="$(mktemp -d)"; chmod 700 "$TMP"; trap 'rm -rf "$TMP"' EXIT
    BASE="https://github.com/$REPO_SLUG/releases/download/$VERSION"
    TARBALL="mynacloud-client-$VERSION.tar.gz"

    curl -fsSL -o "$TMP/$TARBALL" "$BASE/$TARBALL" || die "could not download $TARBALL"
    curl -fsSL -o "$TMP/SHA256SUMS" "$BASE/SHA256SUMS" || die "could not download SHA256SUMS"

    want="$(awk -v f="$TARBALL" '$2 == f || $2 == "*"f {print $1}' "$TMP/SHA256SUMS" | head -1)"
    [[ -n "$want" ]] || die "SHA256SUMS does not mention $TARBALL — refusing to unpack it"
    got="$(SHA "$TMP/$TARBALL")"
    if [[ "$want" != "$got" ]]; then
        echo "  expected $want" >&2; echo "  got      $got" >&2
        die "checksum MISMATCH — not unpacking. Do not retry blindly; ask the operator."
    fi
    say "verified $TARBALL against SHA256SUMS (sha256 ${got:0:16}…)"
    say "NOTE: a checksum served from the same place as the file proves the download was"
    say "      not corrupted. It does not prove it came from us — release signing is not"
    say "      established yet. Read the files before you trust them."

    tar xzf "$TMP/$TARBALL" -C "$TMP" || die "could not unpack $TARBALL"
    SRC="$(find "$TMP" -maxdepth 2 -name tee-claude -type f -print -quit)"
    SRC="${SRC%/tee-claude}"
    [[ -n "$SRC" && -d "$SRC" ]] || die "unpacked tarball does not contain tee-claude"
fi

for f in "${NEED[@]}"; do
    [[ -f "$SRC/$f" ]] || die "$f is missing from $SRC — is this a complete checkout?"
done

mkdir -p "$HOME_DIR" "$BIN_DIR"
install -m 755 "$SRC/tee-claude"            "$HOME_DIR/tee-claude"
install -m 755 "$SRC/websearch-mcp.py"      "$HOME_DIR/websearch-mcp.py"
install -m 755 "$SRC/no-attachment-hook.py" "$HOME_DIR/no-attachment-hook.py"
install -m 644 "$SRC/policy.example.json"   "$HOME_DIR/policy.example.json"
for extra in README.md LICENSE; do
    [[ -f "$SRC/$extra" ]] && install -m 644 "$SRC/$extra" "$HOME_DIR/$extra"
done
say "installed into $HOME_DIR"

ln -sf "$HOME_DIR/tee-claude" "$BIN_DIR/tee-claude"
say "linked   $BIN_DIR/tee-claude"

mkdir -p "$CFG_DIR"; chmod 700 "$CFG_DIR"
say "created  $CFG_DIR (mode 700)"

if [[ -f "$CFG_DIR/policy.json" ]]; then
    say "kept your existing $CFG_DIR/policy.json (not overwritten)"
    POLICY_IS_NEW=0
else
    install -m 600 "$SRC/policy.example.json" "$CFG_DIR/policy.json"
    say "seeded   $CFG_DIR/policy.json from the example"
    POLICY_IS_NEW=1
fi

case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *) echo
       warn "$BIN_DIR is not on your PATH. Add this to your shell profile:"
       warn "    export PATH=\"\$PATH:$BIN_DIR\"" ;;
esac

# ---- what to do next -------------------------------------------------------
cat <<EOF

Next steps
──────────
1. The endpoint's TLS key is ALREADY PINNED in $CFG_DIR/policy.json.
   You do not have to find a value anywhere. It shipped inside this
   release, whose SHA-256 was verified above before anything was
   unpacked — a different root of trust from the certificate the
   endpoint presents, which is what makes check [10] meaningful.

   You are encouraged to check it yourself once the endpoint is up:

       tee-claude --print-spki

   It should equal the value in your policy. If it ever does NOT, do not
   edit your policy to match — that turns a caught problem into an
   uncaught one. Ask us which it is.

2. Dry-run the verifier without starting a session, and read every line:

       tee-claude --verify-only

3. Start a session. It will ask for your session key the first time and
   offer to remember it; nothing is typed on a command line, so nothing
   lands in your shell history:

       tee-claude

Two things to know before you rely on this
──────────────────────────────────────────
• The machine is powered OFF every night and restarted the next day. That
  is a hard outage: in-flight responses are truncated, and the endpoint
  refuses connections until the model has reloaded (on the order of twenty
  minutes after power-on). Its address and port change on every restart,
  which is why the launcher re-reads DNS at every start. If a check fails,
  the machine being off is the most likely explanation.

• The model cannot see images or PDFs. The launcher blocks the paths it can
  (file reads, shell dumps, MCP file tools, @-mentions) — but it CANNOT
  block an image you paste or drag into the prompt box, because that never
  becomes a tool call. If you paste a screenshot, the description you get
  back is invented. Convert to text first.

EOF
if (( POLICY_IS_NEW )); then
    echo "  Your policy is at $CFG_DIR/policy.json — it is yours; read it."
    echo
fi

}

main "$@"
