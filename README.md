# mynacloud client

Run [Claude Code](https://claude.com/claude-code) against a self-hosted, open-weights model
instead of Anthropic's API — and see, before every session, exactly what has and has not been
verified about the machine you are about to send your code to.

That second part is the point of this repository. `tee-claude` runs a numbered list of checks,
prints an honest verdict for each one, tells you what it *cannot* prove, and asks you to type
`yes` before it starts anything.

```
  [08] VERIFIED      TLS handshake OK; chain verified to a system root; hostname matches api.mynacloud.com
  [10] VERIFIED      TLS SPKI matches the policy pin
  [11] VERIFIED      Certificate is ours: issuer Let's Encrypt / YE2, leaf matches api.mynacloud.com
  [14] UNSUPPORTED   Google Confidential VM attestation token
  ...
```

`UNSUPPORTED` is not a pass. It means "this cannot be proven from your machine", it is counted
separately in the summary, and nothing in this program will convert it — or a `FAILED` — into a
`VERIFIED`. There is no override flag. There is no non-interactive consent variable.

---

## Read this before you install

**This is an alpha service, and it is switched off every night.**

The machine is powered down each night and restarted the next day. That is a hard outage with no
drain: an in-flight response is truncated mid-stream, your session stops, and the endpoint
refuses connections until the model has finished loading again — currently on the order of
twenty minutes after power-on. Its public IP address *and* its TCP port both change on every
restart, which is why the launcher looks the port up in DNS every time you start it. **Do not
plan work around this endpoint being reachable.** If a check fails, the most likely explanation
is simply that the machine is off.

**The model cannot see images or PDFs, and left alone it will pretend otherwise.**

This is not "attachments don't work" — it is worse than that. PDFs are dropped in transit, and
images arrive as base64 text that the model cannot interpret, so the model answers *confidently
and wrongly* about a file it never received. Asked for a token inside a test PDF, it invented a
plausible-looking one and put it in a code block as if quoting the document.

The launcher installs a hook that blocks the paths it can see:

| path | covered? |
|---|---|
| `Read` / `NotebookRead` of an image or PDF | yes |
| `cat`, `head`, `base64`, `xxd`, `dd if=` … in a `Bash` command | yes |
| filesystem MCP servers' own read tools | yes |
| `@`-mentioning an image or PDF in your prompt | yes |
| **an image you paste or drag into the prompt box** | **no — see below** |

A pasted or dragged image becomes an attachment at submit time. It is not a tool call, so a
`PreToolUse` hook never sees it, and it is not part of the prompt text, so a `UserPromptSubmit`
hook cannot see it either. There is no client-side interception point, so we do not claim one.
**If you paste a screenshot, the description you get back is invented.** Convert to text first
(`pdftotext` for a PDF; describe an image in words).

SVG is fine — it is text, and the model reads it perfectly well.

**Privacy properties here are configuration, not proof.** Prompts and responses are not logged
or stored, but that is a property of how the endpoint is configured and of source you can read —
it is not cryptographically enforced, and the operator retains the technical ability to reach
data in memory. Every check that *would* prove such a thing (checks [14]–[34]) reports
`UNSUPPORTED`, because the hardware to establish it is not there. Do not send data you cannot
afford to expose.

---

## Install

```sh
git clone https://github.com/Bynesoft-Ltd/mynacloud-client.git
cd mynacloud-client
./install.sh
```

You need `bash`, `python3`, `curl`, `openssl`, and one of `dig` / `host` / `nslookup`. You also
need Claude Code itself:

```sh
npm install -g @anthropic-ai/claude-code
```

`install.sh` copies four files into `~/.local/share/mynacloud-client`, symlinks `tee-claude` into
`~/.local/bin`, creates `~/.tee-claude` with mode 700, and seeds `~/.tee-claude/policy.json` from
the example if you do not already have one. It needs no root and touches nothing outside your
home directory.

### 1. Your credential

```sh
umask 077 && printf '%s' 'YOUR-KEY-HERE' > ~/.tee-claude/token
```

or export `ANTHROPIC_AUTH_TOKEN`. The launcher never prints it, never writes it to a config file,
and never puts it on a command line (`/proc/<pid>/cmdline` is readable by other users on a shared
machine). It is not sent anywhere at all until after you have consented.

### 2. Pin the endpoint's key

The shipped policy has `"tls_spki_sha256": "REPLACE-ME"`, which makes check [10] **FAIL** and the
launcher refuse to start. That is deliberate, not an oversight: an unpinned key means the only
thing standing between you and any certificate the public CA system will issue for this name is
the public CA system.

Take the value from the operator's published release notes. To see what the endpoint is currently
presenting so you can compare:

```sh
tee-claude --print-spki
```

Compare it with the published value **before** you paste it into your policy. Pinning whatever
you happen to see, without comparing, is trust-on-first-use, and is much weaker.

### 3. Try it

```sh
tee-claude --verify-only     # runs every check that needs no credential, then stops
tee-claude                   # verify, disclose, ask, launch
tee-claude -p "explain this repo"   # extra arguments are passed through to claude
```

---

## Your policy file

`~/.tee-claude/policy.json` is **yours**. It is the local statement of what you approved, and it
is never fetched from the endpoint being verified.

```jsonc
{
  "endpoint_scheme": "https",
  "endpoint_host": "api.mynacloud.com",          // pinned. never discovered.
  "port_discovery": {
    "method": "dns-txt",
    "record": "_endpoint.api.mynacloud.com",     // publishes "port=NNNNN"
    "key": "port"
  },
  "model": "deepseek-v4-flash-abliterated",
  "context_window": 491520,
  "max_output_tokens": 32768,
  "min_tls_version": "TLSv1.2",
  "tls_spki_sha256": "REPLACE-ME",
  "expected_issuer_org": "Let's Encrypt",
  "expected_issuer_cn_regex": "^[A-Z]{1,3}[0-9]{1,3}$"
}
```

**Only the port is discovered.** The hostname is pinned here. That is the whole design: the
machine's address and port change nightly, so the port has to come from somewhere dynamic, but
if the *hostname* also came from the network then whoever controlled that record could point you
at a machine of their choosing. As it stands, someone who forges the TXT record can move you to a
different port on a host that still has to pass checks [08], [10] and [11] — and cannot redirect
you anywhere else.

If the TXT record is missing, malformed, ambiguous (two records naming different ports), or not
under the pinned hostname, the launcher stops. It never guesses.

`expected_issuer_org` / `expected_issuer_cn_regex` assert the certificate is *ours*, not merely
*valid*. There is a specific reason. This host's DNS is on Cloudflare in DNS-only mode. If that
record were ever switched to proxied, Cloudflare would terminate TLS and present its own
certificate — the chain would still verify, the hostname would still match, check [08] would
still pass, and a third party would be reading every prompt and every response in plaintext.
Check [11] makes that loud instead of invisible.

### If the operator changes the model

The endpoint may **propose** a different model. When that happens the launcher shows you a diff
(old id and limits → new id, display name, description and limits), asks you to type `yes`, and
only then records it in your policy — keeping the previous file as `policy.json.bak` so a later
silent rollback is detectable. Decline and nothing starts and nothing is written.

The endpoint can never change `endpoint_host`, the TLS pins or the issuer expectation. Those only
change because you changed them.

---

## Web search

Claude Code's built-in `WebSearch` does not work against a self-hosted backend, and it fails in
the worst possible way: it issues a nested request carrying Anthropic's *server-side* search
tool, our backend never produces the result blocks it expects, and Claude Code renders the
model's recollection as though it were a search hit. So the launcher denies `WebSearch` outright
— a loud "not enabled here" instead of a silent fabrication.

In its place it registers `websearch-mcp.py` as a local MCP server. Claude Code runs it as an
ordinary child process on your machine, so **every search request leaves from your computer, with
your IP address and your own optional provider key.** The inference endpoint never sees a query
and never fetches a page for you.

The trade is stated in the consent text before every session: the search terms the assistant
chooses and the addresses of the pages it reads are visible to whichever search engine and
websites are contacted.

No key is required. Quality improves a lot with one:

```sh
# optional. this file must be owned by you and mode 600 — it is PARSED, never executed.
umask 077
cat > ~/.tee-claude/search.env <<'EOF'
BRAVE_API_KEY=...
# or TAVILY_API_KEY=... , or SEARXNG_URL=https://your.searx.instance
EOF
```

or `pip install ddgs` for a keyless multi-engine option. Turn the whole thing off with
`TEE_CLAUDE_SEARCH=off`.

---

## Updating

```sh
tee-claude --update
```

**Release signing is not established yet, and this command will not replace itself until it is.**

What it does today: fetches the release metadata from GitHub, prints the release notes,
downloads the tarball and the release's `SHA256SUMS`, verifies the tarball's SHA-256 against it,
and then **stops** and tells you where the verified download is so you can inspect and install it
yourself.

It stops because a checksum published next to the file it describes proves the download was not
corrupted; it does not prove it came from us. A self-updater that writes an executable to your
machine on that basis is a direct write path into every user's laptop, which would be a bigger
hole than anything this launcher checks for.

When a publisher key is pinned into the launcher and releases are signed, the same command will
verify that signature (Ed25519 over `SHA256SUMS`) and install atomically. Until then, updating is
a deliberate act you perform.

---

## Environment variables

| variable | effect |
|---|---|
| `ANTHROPIC_AUTH_TOKEN` | your session credential (alternative to `~/.tee-claude/token`) |
| `TEE_CLAUDE_POLICY` | path to the policy file |
| `TEE_CLAUDE_CONFIG_DIR` | state directory (default `~/.tee-claude`) |
| `TEE_CLAUDE_SEARCH=off` | disable the client-side web-search server |
| `TEE_CLAUDE_STRICT_MCP=1` | load only our MCP server, not the ones you have configured |
| `TEE_CLAUDE_PORT=NNNN` | skip DNS discovery and use this port (the hostname stays pinned) |

There is deliberately **no** variable that skips a check, consents on your behalf, or turns a
`FAILED` into a pass.

---

## What is in this repository

| file | what it is |
|---|---|
| `tee-claude` | the verifying launcher. One bash file; read it |
| `websearch-mcp.py` | the client-side web-search MCP server. Standard library only, no dependencies |
| `no-attachment-hook.py` | the hook that refuses image/PDF content instead of letting the model invent it |
| `policy.example.json` | the template for your local trust policy |
| `install.sh` | copies four files into your home directory |

No build step, no bundled dependencies, no network access at install time. Everything that runs
on your machine is text you can read in an afternoon.

---

## Reporting a problem

Open an issue at <https://github.com/Bynesoft-Ltd/mynacloud-client/issues>.

For anything security-relevant — a check that passes when it should not, a way to make the
launcher print `VERIFIED` for something it did not verify, or a way to get code to run from a
policy file or a server response — please report it privately through GitHub's security advisory
form on this repository rather than in a public issue.

## Licence

MIT — see [LICENSE](LICENSE).
