#!/usr/bin/env bash
# =============================================================================
# install.sh — put tee-claude and its two helper programs on this machine.
#
# It copies four files, makes a symlink, creates ~/.tee-claude with mode 700 and
# (only if you do not already have one) seeds a policy from the example. It does
# not download anything, does not touch anything outside your home directory,
# and does not need root. Read it — it is short on purpose.
# =============================================================================
set -euo pipefail

SRC="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOME_DIR="${TEE_CLAUDE_HOME:-$HOME/.local/share/mynacloud-client}"
BIN_DIR="${TEE_CLAUDE_BINDIR:-$HOME/.local/bin}"
CFG_DIR="${TEE_CLAUDE_CONFIG_DIR:-$HOME/.tee-claude}"

say()  { printf '  %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }
die()  { printf '  FATAL: %s\n' "$*" >&2; exit 1; }

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

# ---- files -----------------------------------------------------------------
for f in tee-claude websearch-mcp.py no-attachment-hook.py policy.example.json; do
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
1. Put your session credential where the launcher can find it:

       umask 077 && printf '%s' 'YOUR-KEY-HERE' > $CFG_DIR/token

   (or export ANTHROPIC_AUTH_TOKEN in your shell instead)

2. Pin the endpoint's TLS key in $CFG_DIR/policy.json.
   The shipped policy has "tls_spki_sha256": "REPLACE-ME", which makes
   check [10] FAIL and the launcher refuse to start. That is deliberate.
   Take the value from the operator's published release notes. You can see
   what the endpoint is currently presenting with:

       tee-claude --print-spki

   and compare it with the published value before you paste it in.

3. Dry-run the verifier without starting a session, and read every line:

       tee-claude --verify-only

4. Start a session:

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
