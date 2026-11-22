# Approval reminders

For a wait with an explicit resolution path, register the approval once. Glitchrupt plays the selected attention pattern (one 600 ms glitch by default), then reminds you every **15 minutes** while that key remains pending. If two glitches are selected, each plays the entire animation and sound. Resolving the key stops future reminders. The registering chat must resolve it immediately when the user responds or the task becomes unblocked, whichever happens first; the task need not be finished. This uses the native app's timer, not a recurring Codex automation or an open MCP connection.

## Agent tools and CLI

- `glitchrupt_wait_for_approval(key, variant="classic", volume=0.28, sound=true, preview=false)` registers immediately. Its `waiting` response means registered, not that playback has finished. `alert_status` explains scheduling or suppression.
- `glitchrupt_resolve_approval(key=...)` removes the exact wait. Alternatively, `key_prefix` clears a prefix owned by that agent/session; provide exactly one selector.
- `glitchrupt_pending_approvals()` lists keys, `next_reminder_ms`, and whether each key is `muted`.

Use a stable opaque key such as `my-agent:chat-123:decision-1`; never put private questions or tool arguments in a key. Keys accept 1–160 ASCII letters, digits, `.`, `_`, `:`, and `-`. Repeating a registration with the same key does not replay the initial cue, change its settings, or reset its reminder timer. Several waits that become due together share one attention cue; the oldest due wait supplies its sound and preview settings. Each key keeps its own reminder deadline. Native pause, capture permission, Reduce Motion, and shared cue serialization apply. A suppressed reminder does not authorize a retry loop.

```sh
uv run --locked glitchrupt wait my-agent:chat-123:decision-1 --variant classic
uv run --locked glitchrupt pending
uv run --locked glitchrupt resolve --key my-agent:chat-123:decision-1
```

For a windowed test, add `--preview --silent` to `wait`; resolve its key afterwards. The menu-bar **Attention pattern** selects one or two glitches; **Gap between glitches** sets the gap from 0 to 2000 ms in 100 ms steps when two are selected. These settings persist and apply to subsequent cues. The 15-minute reminder interval remains fixed. A normal `signal` still plays one configurable cue. Agents must resolve a key immediately when the user responds or the work becomes unblocked, whichever happens first, including cancellation. The app also offers a clear-reminders control for stale waits. Pending state is local and in memory; quitting the app clears it.

## Banner and pending list (0.4.0)

Include optional `chat_name` (1–100 Unicode scalar values), `reason` (1–240), and `chat_id` (canonical lowercase UUID) in a wait. Use a short, nonsensitive summary rather than raw prompts, commands, credentials, or transcripts. Control characters are rejected. The context passes through the existing private local IPC and lives in the native registry; it is never written to diagnostic logs. The bridge's short-lived request/response files retain their existing private permissions and aging policy.

```sh
uv run --locked glitchrupt wait example:decision-1 \
  --chat-name "Example chat" --reason "Approve the example test run" \
  --chat-id 01234567-89ab-4cde-8012-3456789abcde
```

Replace that fictional UUID with the actual chat ID. MCP accepts the same three optional argument names. Older connected MCP sessions may need a connection refresh to discover them; the updated CLI can be used meanwhile. Re-registering an existing key can enrich its context without replaying its cue, changing playback settings, or moving its deadline.

After a completed attention cue, Glitchrupt shows a passive top-right banner for eight seconds on the display under the pointer. Hover pauses dismissal. The banner does not activate another app. Only a user click on **Open chat** opens a fixed entry link: `codex://threads/<chat_id>` for Codex, or `claude://code/continue?session=local_<UUID>` for a Claude Desktop Code session. IDs are validated, arbitrary URLs and prompt/query parameters are not accepted. Missing IDs show request details instead. Multiple coalesced requests share a banner with a count and all remain in the menu list. While desktop motion is suppressed by Reduce Motion or unavailable screen access, a static banner can still identify the request. Pausing agent cues, or a timed mute, suppresses banners as well as glitches.

The banner's **Mute** pull-down sits left of the main button and offers three choices. Each one dismisses the banner.
- **Mute this request** silences the request the banner names at its top, which is the first one when several share a banner. Its key stays pending, and its menu entry gains a `(muted)` suffix.
- **Mute all for 1 hour** pauses every agent cue until a fixed wall-clock time. The menu shows **Agent cues muted until <time>**, and clicking that item ends the mute early.
- **Pause all agent cues** is the existing indefinite pause.

The Mute control does not appear on the preview banner.

The **Waiting for input** submenu retains each request until its agent resolves it, the user chooses **Stop this reminder** / clears reminders, or Glitchrupt quits. Each request's submenu also has **Mute this request** / **Unmute this request**. Opening a chat, dismissing a banner, or muting does not approve or resolve anything. Resolving a visible request removes it from both UI surfaces, including a muted one. No pending queue is restored after an ordinary quit or crash.

Create one live structured input control before registering the cue; the banner is an attention aid, not that input control. Synthetic preview and verification keys must be resolved after testing.

## Per-chat ownership

Each chat registers its own stable approval key and clears that key at the start of processing the user’s response, or as soon as the task becomes unblocked. Glitchrupt owns all timers in the same resident Mac app, so the chat does not need a heartbeat, an extra monitor chat, or a model turn every fifteen minutes. A response ends the current wait even if work is unfinished; a genuinely new approval needs a new key. The app cannot infer a response by itself, so the registering agent must make the resolve call.

## Codex lifecycle adapter: initial cue only

**Automatic Codex hooks play the initial configured cue only. They do not enable recurring reminders.** The current hook feed does not reveal when an approval is answered. `PostToolUse` arrives after a tool finishes, which may be much later. Repeating against that signal could falsely keep alerting after approval. The adapter therefore sends an internal `repeat=false` registration; the app removes it after the initial effect or suppression. Responses include `repeat=false`; `repeat_interval_ms` still describes the fixed 900000 ms recurring policy and does not schedule a one-shot reminder. Full 15-minute repetition requires an explicit wait/resolve MCP workflow or a future verified approval-resolution feed.

[`examples/approval-hooks.json`](../examples/approval-hooks.json) is an opt-in template. Replace the two absolute paths, merge it with existing user or project hooks, then review and trust it in Codex. Do not overwrite other hook definitions. The same command handles six events:

| Event | Action |
| --- | --- |
| `PermissionRequest` | Request one initial configured cue, without recurring reminders. |
| Matching `PostToolUse` | Best-effort cleanup once the tool finishes; this is not approval-resolution evidence. |
| `Stop`, `Interrupt`, `SessionEnd`, `UserPromptSubmit` | Clear the session's keys to prevent orphan reminders. |

The adapter is `glitchrupt hook`. It reads one bounded JSON event from standard input, writes exactly `{}` followed by a newline to standard output, always exits zero, and never grants, denies, or changes an approval. This benign JSON response also satisfies events such as `Stop` that require valid JSON on success. Operational failures produce only a generic message on standard error. Hook input is bounded at 256 KiB. Do not enable asynchronous execution: synchronous dispatch preserves registration/cleanup ordering. The native request timeout is 1.5 seconds; host-level `Interrupt`/`SessionEnd` hooks have a maximum of three seconds, so host cancellation remains possible during a slow app launch.

Only `hook_event_name`, `session_id`, and, for tool correlation, `turn_id`, `tool_name`, and `tool_input` are used. Session IDs and canonicalized tool data become SHA-256 identifiers; the raw event, transcript, question, command, and result are never saved or forwarded to the native app. The adapter does not read `transcript_path`. The `tool_use_id` present only after execution is deliberately ignored. Shell aliases normalize to the same tool identity; sorted JSON object keys make equivalent tool inputs correlate.

## Coverage and practical limits

This is best-effort lifecycle coverage, not a universal monitor of all Codex chats. Hooks must be trusted and supported in the current client. A denied tool may have no `PostToolUse`; another hook may grant an approval immediately; a long-running approved tool may finish much later than the approval answer. These limitations are why automatic hook registrations are one-shot. Cleanup on new user activity, stop, interrupt, or session end also resolves owned keys when those events arrive. Codex currently supplies the parent session ID for subagent hooks, so session cleanup can clear that parent's subagent reminders too. For explicitly recurring MCP registrations, a crash or missed cleanup event can leave a key registered until manually cleared or Glitchrupt quits.

Browser-use prompts, such as a download permission inside a running browser tool, are not verified by this integration. The model can be suspended before it has an opportunity to register a wait. A global instruction cannot close that gap by itself. Hook trust must also be completed before supported hooks can run.

Ordinary clarification questions and specialized asynchronous input tools are not guaranteed to emit `PermissionRequest`. For those waits, the agent must explicitly call the wait/resolve MCP tools under an agreed instruction. Avoid using both a model-created key and the hook for the same permission event, since unrelated keys cannot be deduplicated automatically. Do not send tool contents or transcripts to Glitchrupt to infer approval state.

Event fields and trust behavior follow [official Codex hook documentation](https://learn.chatgpt.com/docs/hooks), checked 2026-10-25. The source template itself does not install or trust hooks, change global MCP configuration, or add an `AGENTS.md` rule.

## Development check

Run `uv run --locked --group dev python -m pytest -q` from the checkout. Using `python -m pytest` selects the locked project interpreter even when an unrelated system `pytest` executable is on `PATH`. The lifecycle adapter is a separate CLI mode; its benign JSON output does not enter the MCP stdio stream.

The registration response includes `pattern_glitches` and `pattern_gap_ms` for the current menu settings. These settings may change before a reminder plays. The older `gap_ms: 200` field is retained solely for compatibility with existing clients; use `pattern_gap_ms` for the selected gap.

Claude Desktop Code sessions can pass `claude_session_id: local_<UUID>` instead of a Codex `chat_id`. On user click the app opens `claude://code/continue?session=local_<UUID>`, the Claude desktop app's supported entry link for that session. IDs are strictly validated and arbitrary URLs are not accepted. The two fields are mutually exclusive. Existing sessions may need to reconnect to discover the updated MCP schema.
