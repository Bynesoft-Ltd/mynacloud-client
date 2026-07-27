# mynacloud client

Run [Claude Code](https://claude.com/claude-code) against a self-hosted, open-weights model
instead of Anthropic's API.

Before every session, `tee-claude` runs a numbered list of checks against the endpoint, prints
an honest verdict for each, tells you what it **cannot** prove, and waits for you to type `yes`.

```
  [08] VERIFIED      TLS handshake OK; chain verified to a system root; hostname matches api.mynacloud.com
  [10] VERIFIED      TLS SPKI matches the policy pin
  [11] VERIFIED      Certificate is ours: issuer Let's Encrypt / YE2, leaf matches api.mynacloud.com
  [14] UNSUPPORTED   Google Confidential VM attestation token
```

`UNSUPPORTED` is not a pass — it means "cannot be proven from your machine". Nothing here
converts an `UNSUPPORTED` or a `FAILED` into a `VERIFIED`. There is no override flag and no
non-interactive consent variable.

---

## Quickstart

You need `bash`, `python3`, `curl`, `openssl`, one of `dig`/`host`/`nslookup`, and Claude Code:

```sh
npm install -g @anthropic-ai/claude-code
```

Then download the installer, **read it**, and run it:

```sh
curl -fLO https://raw.githubusercontent.com/Bynesoft-Ltd/mynacloud-client/main/install.sh
less install.sh
bash install.sh
```

It fetches the latest release tarball, verifies its SHA-256 against the release's `SHA256SUMS`
before unpacking, and installs into your home directory. No root, nothing outside `$HOME`.

> Deliberately **not** `curl … | bash`. Piping into a shell means the thing you audited and the
> thing that ran were two different fetches. Same reason `--update` won't install itself — see
> [Updating](#updating).

Then:

**Start a session.** It asks for your session key the first time and offers to remember it. The
endpoint's TLS key is [already pinned](#the-endpoints-key-is-already-pinned) for you.

```sh
tee-claude --verify-only            # run every check that needs no credential, then stop
tee-claude                          # verify, disclose, ask, launch
tee-claude -p "explain this repo"   # extra arguments pass through to claude
```

---

## Four limits to know before you rely on this

| | |
|---|---|
| **It stops at 20:00 Europe/Kyiv, every day.** | ~21 min to reload after it is started again the next morning, and its IP *and* port change every restart. If a check fails, the machine being off is the likeliest reason. → [detail](#the-nightly-outage) |
| **It cannot see images or PDFs.** | Almost every path fails *loudly*. One path — an image file read from disk — would silently invent a description, and the bundled hook blocks exactly that. → [detail](#images-and-pdfs) |
| **Privacy here is configuration, not proof.** | Prompts aren't logged, but that is how the endpoint is configured — not something cryptography enforces. → [detail](#what-privacy-does-and-does-not-mean) |
| **`/cost` overstates your spend by about 36×.** | Claude Code prices this model as if it were Anthropic's most expensive tier. The endpoint's own figure is the one you are billed on. → [detail](#cost-is-not-what-you-are-billed) |

---

## The endpoint's key is already pinned

`policy.example.json` ships with `tls_spki_sha256` **filled in**, so a fresh install has a
working pin and check `[10]` passes. You do not have to hunt for a value.

That pin reached you inside this repository — release tarball, checksum-verified against the
release's `SHA256SUMS` before anything was unpacked. That is a **different root of trust** from
the certificate `api.mynacloud.com` presents, which is the whole point: at check `[10]` two
independent sources have to agree.

It is not trust-on-first-use. TOFU would be pinning whatever the endpoint happens to present on
your first connection, with nothing to compare against. Nothing here does that, and no flag will.

You can check it yourself, and you are encouraged to:

```sh
tee-claude --print-spki      # what the endpoint is presenting right now
```

It should equal the value in your `~/.tee-claude/policy.json`.

> **If it does not match, do not edit your policy to make the error go away.** A mismatch is one
> of exactly two things: a key rotation you were not told about, or someone presenting a
> certificate that is not ours. Ask which — overwriting the pin with whatever the endpoint showed
> you converts a caught problem into an uncaught one.

Emptying the field, or setting it back to `REPLACE-ME`, makes `[10]` **FAIL** and the launcher
refuse to start. That is deliberate: an unpinned key leaves the public CA system as the only
thing between you and any certificate issued for this name.

## Your policy file

`~/.tee-claude/policy.json` is **yours**. It is the local statement of what you approved — the
launcher never fetches it from the endpoint being verified.

The endpoint may *propose* a change to the served model. You get a diff and must type `yes`;
the change is then recorded, with a `.bak` kept. It can never change `endpoint_host`, the TLS
pins, or the issuer expectation — those are what make "this is the right endpoint" mean
anything, and they change only because you changed them.

Only the **port** is discovered at launch, from a DNS TXT record, because it changes on every
restart. Consequence worth understanding: anyone who tampers with that record can move you to a
different port on a host that still has to pass every certificate check. They cannot move you
to a different host.

---

## Images and PDFs

The model is text-only. Measured, per path:

| what you do | what happens |
|---|---|
| attach or paste an image | **clean 400** — loud, you cannot miss it |
| attach a PDF | **clean 400** — loud |
| `Read` a PDF from disk | **clean 400** — loud |
| **`Read` an image file from disk** | **200, and the model invents a description** |

Only that last row is dangerous, and it is the one the bundled
`no-attachment-hook.py` exists to stop — it refuses `Read`/`NotebookRead` of an image, and
also `cat`, `head`, `base64`, `xxd`, `dd if=` in a `Bash` command, filesystem MCP read
tools, and `@`-mentions of an image. Verified: the hook denies a `Read` of a PNG.

So the hook is **load-bearing, not belt-and-braces.** If you disable it, an image file read
from disk comes back as a confident description of something the model never saw. Asked for
a token inside a test PDF, it invented a plausible-looking one and put it in a code block as
if quoting the document.

Convert to text first — `pdftotext` for a PDF, describe an image in words. SVG is fine: it
is text, and the model reads it well.

## The nightly outage

**The service stops at 20:00 Europe/Kyiv, seven days a week** (17:00 UTC in summer, 18:00
UTC in winter — it follows Kyiv local time, not a fixed UTC hour). It is started again in
the morning **by hand**, so there is no guaranteed opening time.

The shutdown gives in-flight work **180 seconds to finish** and takes a final database
snapshot before stopping, so a request already running will usually complete. A request
that outlives the drain is cut mid-stream.

Coming back takes **~21 minutes** — the model is a 148 GiB checkpoint and the endpoint
refuses connections until it has loaded. Its public IP *and* TCP port both change on every
restart, which is why the launcher re-reads the DNS TXT record at every start.

**Do not plan work around this endpoint being reachable**, and do not start a long task at
19:45 Kyiv.

## What privacy does and does not mean

Prompts and responses are not logged or stored. That is a property of how the endpoint is
configured, and of source you can read — it is not cryptographically enforced, and the operator
retains the technical ability to reach data in memory.

Every check that *would* prove otherwise (`[14]`–`[34]`) reports `UNSUPPORTED`, because the
hardware to establish it is not there. **Do not send data you cannot afford to expose.**

---

## `/cost` is not what you are billed

Claude Code works the number out on your machine. It takes the token counts the endpoint
returns and multiplies them by prices from a table compiled into Claude Code — and that table
only covers Anthropic's own models. This endpoint does not serve one, so there is no entry for
it and Claude Code falls back to a default of **$5.00 per million input tokens and $25.00 per
million output**, which are Anthropic Opus-tier rates.

The rates configured on this endpoint are **$0.14 per million input tokens and $0.28 per
million output** — about 36× cheaper. So every figure `/cost` and the end-of-session summary
show is inflated by roughly that factor. A measured session:

| | input tokens | output tokens | `/cost` said | actually cost |
|---|---|---|---|---|
| one session | 125,128 | 793 | **$0.64547** | **$0.01774** |
| four sessions | | | **$6.20** | **$0.386** |

Claude Code knows it is guessing: when this happens it appends *"(costs may be inaccurate due
to usage of unknown models)"* to the total in the end-of-session summary. That warning is the
only signal you get, and `/cost` itself does not carry it.

**Nothing you can set fixes this.** There is no setting, environment variable or policy key
that supplies a price for a model Claude Code does not ship a price for — it takes per-model
rates only from a table compiled into the binary, or from account configuration delivered by
Anthropic's own API, and neither can describe this model. The cost this endpoint returns in
the response headers (below) is not something Claude Code reads. Read `/cost` as a token
counter with the wrong multiplier, and divide by ~36 if you want a rough figure.

**The billing figure comes from the endpoint.** Every completion response carries it in the
headers:

| header | what it is |
|---|---|
| `x-litellm-response-cost-original` | USD cost of that single request |
| `x-litellm-key-spend` | your running total on this credential, in USD |
| `x-litellm-key-max-budget` | the ceiling that is actually enforced |

Those three ride on `/v1/messages` and `/v1/chat/completions` responses only. `/v1/models` and
`/v1/messages/count_tokens` do not carry them, and the `/spend` and key-management routes are
not published, so there is no way to read your balance without making a real request — ask the
operator if you need a readout.

### Do not rely on `--max-budget-usd`

Claude Code checks that flag against its own inflated figure, so it will stop a session at
roughly **1/36th** of the budget you asked for.

The ceiling that actually holds is `max_budget` on your credential. The endpoint enforces it
with the correct rates, independently of anything on your machine, and it is unaffected by this
bug. Ask the operator to change it if you need a different limit.

---

## Web search

The model has no built-in search. `websearch-mcp.py` runs locally and gives it one; it is
standard library only, with no dependencies.

Optional API keys go in `~/.tee-claude/search.env`, which must be owned by you and mode 600 —
it is **parsed, never executed**:

```sh
BRAVE_API_KEY=...
# or TAVILY_API_KEY=... , or SEARXNG_URL=https://your.searx.instance
```

Without a key it falls back to a public instance. Disable it entirely with
`TEE_CLAUDE_SEARCH=off`.

---

## Windows

Use **WSL2**, and install exactly as above inside your Linux distribution. Claude Code and the
launcher both run there unmodified.

Native Windows (PowerShell) is not supported, and the reason is not laziness: several checks
rest on POSIX file ownership and permissions — that your token is mode 600, that `search.env`
is not writable by anyone else, that `~/.tee-claude` is 700. Those checks cannot mean the same
thing on NTFS without being rewritten against Windows ACLs, and this launcher's whole premise
is that it does not report `VERIFIED` for something it did not verify. Git Bash appears to work
and would quietly weaken exactly those guarantees, so it is not recommended.

---

## Updating

```sh
tee-claude --update
```

**Release signing is not established yet, so this command will not replace itself.** It fetches
the release metadata, prints the notes, downloads the tarball and `SHA256SUMS`, verifies the
tarball's SHA-256 — then **stops** and tells you where the verified download is, so you can
inspect and install it yourself.

Why it stops: a checksum published next to the file it describes proves the download was not
corrupted. It does not prove it came from us. A self-updater acting on that is a direct write
path into every user's laptop — a bigger hole than anything this launcher checks for.

When a publisher key is pinned and releases are signed, the same command will verify that
signature (Ed25519 over `SHA256SUMS`) and install atomically. Until then, updating is a
deliberate act you perform.

---

## Environment variables

| variable | effect |
|---|---|
| `ANTHROPIC_AUTH_TOKEN` | your session credential (skips the prompt) |
| `TEE_CLAUDE_POLICY` | path to the policy file |
| `TEE_CLAUDE_CONFIG_DIR` | state directory (default `~/.tee-claude`) |
| `TEE_CLAUDE_SEARCH=off` | disable the client-side web-search server |
| `TEE_CLAUDE_STRICT_MCP=1` | load only our MCP server, not the ones you have configured |
| `TEE_CLAUDE_PORT=NNNN` | skip DNS discovery, use this port (hostname stays pinned) |

There is deliberately **no** variable that skips a check, consents on your behalf, or turns a
`FAILED` into a pass.

Your credential is never printed, never written to a config file by us, and never placed on a
command line (`/proc/<pid>/cmdline` is readable by other users on a shared machine). Nothing is
sent anywhere until after you have consented.

---

## What is in this repository

| file | what it is |
|---|---|
| `tee-claude` | the verifying launcher. One bash file; read it |
| `websearch-mcp.py` | client-side web-search MCP server. Standard library only |
| `no-attachment-hook.py` | refuses image/PDF content instead of letting the model invent it |
| `policy.example.json` | template for your local trust policy |
| `install.sh` | installs the above into your home directory |

No build step, no bundled dependencies. Everything that runs on your machine is text you can
read in an afternoon.

---

## Reporting a problem

Open an issue at <https://github.com/Bynesoft-Ltd/mynacloud-client/issues>.

For anything security-relevant — a check that passes when it should not, a way to make the
launcher print `VERIFIED` for something it did not verify, or a way to get code to run from a
policy file or a server response — please use GitHub's private security advisory form on this
repository rather than a public issue.

## Licence

MIT — see [LICENSE](LICENSE).
