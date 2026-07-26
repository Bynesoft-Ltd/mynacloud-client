#!/usr/bin/env python3
"""Claude Code hook: refuse image/PDF content instead of letting the model invent it.

WHY THIS EXISTS — measured on this deployment, not theorised:

- **PDF**: the gateway's Anthropic->Responses translator has no `document` branch at all, so a
  PDF is SILENTLY DROPPED. Asked for the token inside a test PDF containing
  `SECRET_PDF_TOKEN_XY99`, the model confidently answered `FELIX_THE_SECRET_KEY` and wrapped it
  in a code block as if quoting the file. No error, no hedge — a fabricated answer
  indistinguishable from a real one.

- **Image**: images ARE forwarded, as base64 text. The model has no vision, but the encoded
  bytes land in its context. On an 8x8 solid PNG it correctly reported `violet (RGB #8a2be2)` —
  the exact value — because a tiny solid image is trivially recoverable from the encoded bytes.
  That looks like working vision, which is precisely the danger: on a real screenshot the base64
  is kilobytes-to-megabytes of context burned, and the description is invented. The same run
  also hallucinated "a scene with the sky as the dominant feature" for a solid square.

So the failure mode is not "attachments don't work" but "attachments produce confident fiction".

WHAT THIS HOOK COVERS
  PreToolUse / Read, NotebookRead   the obvious path
  PreToolUse / Bash                 `cat`, `head`, `base64`, `xxd` ... reach the same bytes and
                                    put them in the transcript just as effectively
  PreToolUse / mcp__*               filesystem MCP servers ship their own read tools
  UserPromptSubmit                  `@`-mentions, which expand into content client-side and
                                    never become a tool call at all

WHAT IT CANNOT COVER — stated plainly, because pretending otherwise is the actual hazard
  An image PASTED or DRAGGED straight into the prompt box. Claude Code attaches it as an image
  content block at submit time. It is not a tool call, so PreToolUse never sees it; and it is
  not part of the prompt *text*, so UserPromptSubmit cannot see it either. There is no
  client-side interception point. If you paste a screenshot, the model will describe something
  that is not there. This is disclosed in the launcher's consent text and in the README.

  Equally, an arbitrary program that happens to read a file — `python3 -c "open('x.png','rb')"`,
  a script, a compiler — is not something a command-line matcher can enumerate. The Bash rules
  below cover the common content-dumping utilities, not everything conceivable.

`.svg` is deliberately NOT blocked: it is text, the model reads it perfectly well, and blocking
it was a bug.

Remove this hook if the backend ever gains real vision AND the gateway gains a document branch.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import sys

# Binary formats the model cannot actually see. SVG is text and is readable — do not add it.
BLOCKED = {
    ".png", ".jpg", ".jpeg", ".gif", ".webp", ".bmp", ".tiff", ".tif", ".ico", ".heic", ".heif",
    ".avif", ".jfif", ".pdf",
}

# Utilities whose whole job is to put a file's bytes on stdout, where they become
# transcript the model reads. Deliberately a short allowlist rather than a
# blocklist of everything: a false positive here blocks a customer's real work.
READERS = {
    "cat", "bat", "batcat", "tac", "rev", "nl", "head", "tail", "less", "more", "most",
    "od", "xxd", "hexdump", "hd", "strings", "base64", "b64encode", "uuencode", "openssl",
    "xclip", "xsel", "pbcopy",
}
# Commands that take the file as the value of an option rather than a bare argument.
DD_LIKE = {"dd"}

_REASON_CORE = (
    "this deployment has no vision capability, and PDFs are dropped in transit. The model would "
    "not receive the file, yet it would still answer confidently about it — a fabricated result "
    "indistinguishable from a real one. Extract the content to text first (pdftotext, or "
    "describe the image in words) and use that instead."
)
REASON_READ = "Refused by the endpoint policy: " + _REASON_CORE
REASON_BASH = (
    "Refused by the endpoint policy: this command would put the raw bytes of an image or PDF "
    "into the conversation, and " + _REASON_CORE
)
REASON_PROMPT = (
    "This session cannot read images or PDFs: the endpoint has no vision and PDFs are dropped "
    "in transit, so the assistant would describe the file confidently and wrongly rather than "
    "fail. Remove the @-mention below and supply the content as text instead "
    "(pdftotext for a PDF; a written description for an image).\n\nBlocked attachment(s): {names}"
)


def is_blocked(path: str) -> bool:
    if not isinstance(path, str) or not path:
        return False
    # Strip a URI scheme and any query/fragment before looking at the extension.
    p = re.sub(r"^[a-zA-Z][a-zA-Z0-9+.-]*://", "", path)
    p = p.split("?", 1)[0].split("#", 1)[0]
    return os.path.splitext(p.lower())[1] in BLOCKED


def deny(reason: str) -> int:
    json.dump(
        {
            "hookSpecificOutput": {
                "hookEventName": "PreToolUse",
                "permissionDecision": "deny",
                "permissionDecisionReason": reason,
            }
        },
        sys.stdout,
    )
    return 0


def walk_paths(value, depth: int = 0):
    """Yield every string that looks like it could be a path, from any tool input shape.

    MCP filesystem servers are not standardised: the argument may be `path`, `file`,
    `uri`, `paths`, a list, or nested. Rather than enumerate server-specific schemas,
    walk the whole input and test every string.
    """
    if depth > 6:
        return
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from walk_paths(v, depth + 1)
    elif isinstance(value, (list, tuple)):
        for v in value:
            yield from walk_paths(v, depth + 1)


def bash_hits(command: str) -> list[str]:
    """Return blocked files this shell command would dump into the transcript.

    Split on shell separators, then only flag a segment whose *command word* is a
    known content dumper. `rm x.png`, `mv a.png b.png`, `ls *.png` and `pdftotext
    in.pdf out.txt` are all left alone on purpose — none of them puts image bytes
    in front of the model.
    """
    hits: list[str] = []
    for segment in re.split(r"(?:\|\||&&|[;\n|&()])", command or ""):
        segment = segment.strip()
        if not segment:
            continue
        try:
            words = shlex.split(segment, comments=True)
        except ValueError:
            words = segment.split()
        # skip leading VAR=value assignments and common prefixes
        i = 0
        while i < len(words) and (re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", words[i])
                                  or words[i] in ("sudo", "command", "nohup", "time", "env")):
            i += 1
        if i >= len(words):
            continue
        cmd = os.path.basename(words[i])
        args = words[i + 1:]
        if cmd in READERS:
            hits += [a for a in args if is_blocked(a)]
        elif cmd in DD_LIKE:
            hits += [a.split("=", 1)[1] for a in args
                     if a.startswith("if=") and is_blocked(a.split("=", 1)[1])]
    return hits


def handle_pre_tool_use(payload: dict) -> int:
    tool = payload.get("tool_name") or ""
    ti = payload.get("tool_input")
    if not isinstance(ti, dict):
        return 0

    if tool == "Bash":
        hits = bash_hits(ti.get("command") or "")
        if hits:
            return deny(REASON_BASH + "\n\nBlocked: " + ", ".join(sorted(set(hits))[:5]))
        return 0

    # Read, NotebookRead, and every MCP tool: test every string in the input.
    for s in walk_paths(ti):
        if is_blocked(s):
            return deny(REASON_READ + "\n\nBlocked: " + s[:200])
    return 0


def handle_user_prompt_submit(payload: dict) -> int:
    prompt = payload.get("prompt")
    if not isinstance(prompt, str) or "@" not in prompt:
        return 0
    # @-mentions: `@path/to/file.png`, optionally quoted. Only look at tokens that
    # start a word, so an email address or a decorator is not mistaken for one.
    names = []
    for m in re.finditer(r'(?:(?<=\s)|^)@("([^"]+)"|\'([^\']+)\'|([^\s"\']+))', prompt):
        cand = m.group(2) or m.group(3) or m.group(4) or ""
        if is_blocked(cand):
            names.append(cand)
    if not names:
        return 0
    json.dump(
        {
            "decision": "block",
            "reason": REASON_PROMPT.format(names=", ".join(sorted(set(names))[:5])),
        },
        sys.stdout,
    )
    return 0


def main(argv: list[str]) -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        # Never break a tool call because the hook could not parse its input. This
        # is a fail-open, and it is the right one: the hook is a usability guard
        # against fabrication, not a security boundary, and a hook that crashes
        # the customer's editor is worse than one that misses a case.
        return 0
    if not isinstance(payload, dict):
        return 0

    event = payload.get("hook_event_name") or payload.get("hookEventName") or ""
    if "--prompt" in argv or event == "UserPromptSubmit":
        return handle_user_prompt_submit(payload)
    return handle_pre_tool_use(payload)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
