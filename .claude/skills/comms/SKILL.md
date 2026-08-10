---
name: comms
description: Reply triage — a single ranked list of everyone waiting on a response from you across texts, email, and Slack (people who wrote and you haven't answered), split into Work and Personal. Use when the user invokes /comms or asks "who am I on the hook to reply to", "what do I owe responses on", "clear my inbox", or "who's waiting on me".
---

# /comms

Answer one question: **who is waiting on a reply from me, and what should I say?**
Pull every conversation — text, email, and Slack — where someone wrote and the
ball is in my court, then rank it into **Work** and **Personal** so the reader
can clear the list top-down. Access is local/read-only: you can never send. You
may only create Gmail drafts, and only when asked.

This is the reply-triage counterpart to `/morning`'s "Needs a response"
section, but deeper and standalone: every open thread, not just the highlights.

## Step 0 — Context

Read `docs/people-and-workstreams.md` first: who people are, VIPs, household
services, kids' world, and what counts as noise. Every keep/drop and priority
call below is made against it.

## Step 1 — Gather (run in parallel via Bash)

```bash
date "+%A %Y-%m-%d %H:%M"                                   # anchor "today"/ages
scripts/imessages.py needs-reply --days 14 --json          # texts awaiting my reply
scripts/gmail.py needs-reply --days 14 --json --limit 40   # email threads awaiting my reply
scripts/slack.py needs-reply --days 14 --json              # Slack DMs, LOCAL-TOKEN workspaces (Plum Growth)
```

The text/email/local-Slack commands each filter to threads whose **last**
message is inbound (not from me), so anything I've already answered is gone.
`slack.py` spans every locally-authorized workspace at once and tags each item
with its `workspace`.

**Slack — Bobsled comes from the MCP connector, not the local script.** Bobsled
is authorized through the claude.ai Slack connector (`mcp__claude_ai_Slack__*`),
so pull it via those tools instead of a token:
1. `slack_search_public_and_private` with `query:"to:me after:<YYYY-MM-DD 14d ago>"`,
   `channel_types:"im,mpim"`, `sort:"timestamp"` — recent messages sent *to me*
   in DMs/group-DMs (i.e. someone wrote me).
2. Dedupe by conversation. For each, `slack_read_channel` (channel_id = the other
   person's user_id for a DM) `limit:1` to check the newest message: if it's from
   **me**, I already replied — drop it; if it's from **them**, it's awaiting me.
3. Skip bot/app/Slackbot DMs. These land in the **Work** bucket, tagged `slack:bobsled`.
If the `mcp__claude_ai_Slack__*` tools aren't connected this session, note
"Bobsled Slack unavailable (connector offline)" in the Work section — don't fail.

Notes:
- `--days 14` is the default window. Widen it if the user asks ("last month").
- Warnings on stderr like `skipping <account>` mean a stale Google token — keep
  going and footer: run `scripts/google_auth.py add`.
- If `slack.py` prints "No Slack workspaces authorized yet," the local Slack layer
  isn't set up — just rely on the MCP connector for Bobsled and skip the rest;
  don't warn.
- If a whole channel errors, say so in that section — never fabricate.
- Want just one channel? Skip that command. `--account <substr>` scopes email to
  one mailbox; `--workspace <substr>` scopes local Slack to one workspace.

## Step 2 — Synthesize (apply judgment; never dump raw output)

**Drop the noise.** These are not "people waiting on me":
- Cold sales / outreach, newsletters, promos, "welcome"/setup mail, security
  alerts, receipts, and automated notifications — even when they end a thread.
  Watch for cold outreach dressed as a personal reply (`Re:` on a first-contact
  sales email); the people doc and sender domain give it away.
- Automated texts: shortcodes and RBM/business senders (Verizon, delivery bots).
  Keep a genuinely actionable automated text (a doctor's confirmation, a
  contractor) but not marketing.
- Tapbacks and one-emoji/one-word group banter ("😍", "Go Brucie!") — a group
  thread only makes the list if it has a **direct question to me** or a
  **logistics commitment** (a date, an RSVP, someone coming to the house, who's
  covering pickup).
- Slack: `needs-reply` already drops Slackbot/app DMs. A group DM (mpim) counts
  only if there's a direct ask to me, same bar as a group text.

**Keep and rank what remains.** A real person writing to me directly outranks
everything. For each kept item work out:
- **Who** (contact name, not a raw handle) and **channel** (text / which mailbox /
  which Slack workspace).
- **What they actually need** — one line, in plain terms ("confirm Sat dinner",
  "answer his pricing question", "RSVP for Bruce").
- **How long it's been waiting** ("3d") — aging items rise.
- Whether it's a **quick reply** (yes/no, a time, a thanks) vs. one needing real
  thought — quick + old should be cleared first.

Priority order, highest first: (1) VIPs and family/kids logistics with a time
element, (2) direct questions from real people aging past a couple days,
(3) quick acknowledgements, (4) everything else worth a reply. Dedupe anyone who
reached out on more than one channel into a single line.

## Step 3 — Format

Split by **life area, not by medium** — Work vs Personal, each in priority order.
Use `docs/people-and-workstreams.md` to place people: Bobsled / Plum Growth /
Snapfix contacts and all Slack DMs are **Work**; family, friends, kids, school,
household services, medical are **Personal**. Show the channel as a small tag on
each line.

```
# Reply triage — {Weekday, Mon D}  ·  {N} waiting

## Work
Highest-stakes first. If nothing's genuinely owed, say so in one line.
- **Name** · {channel: text / [mailbox] / slack:workspace} · {age} — what they
  need. _Suggested: one-line reply._

## Personal
- **Name** · {channel} · {age} — what they need. _Suggested: …_

## Can wait
One-liners for the low-stakes tail — acks, FYIs, soft asks. No detail needed.
```

Rules:
- Bold names; keep ages short (`3d`, `today`). Never print thread IDs, message
  IDs, channel IDs, or account tokens unless asked.
- Within Work and Personal, lead with a "reply first" cluster (VIPs / time-
  sensitive / aging) before the rest — don't make a separate top section.
- Every actionable item gets a concrete one-line suggested reply the user could
  send as-is.
- Keep the whole thing scannable — aim under ~40 lines; roll the long tail into
  "Can wait".
- End with: **"Want me to draft any of these?"** Drafting creates a Gmail draft
  only (`scripts/gmail.py draft --account <mailbox> --to … --subject … --body …`);
  it never sends. There is **no send path for texts or Slack** — for those, hand
  the user the suggested wording to send themselves.
