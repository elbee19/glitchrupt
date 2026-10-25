# Glitchrupt + Codex

**MCP gives Codex the button. A hook decides when to press it automatically.**

Glitchrupt already has a local stdio MCP server and a CLI. Either route asks the same native Mac app to play one cue. The app works over the desktop while another app is in front; Codex does not need to stay in the foreground. Its pause control, five-second cooldown, capture permission, and Reduce Motion setting still apply.

## Connect the MCP tools

Build `Glitchrupt.app`, then run `uv sync --locked` in this checkout. Replace the example paths below with your actual `uv` executable and checkout location:

```sh
codex mcp add glitchrupt \
  --env GLITCHRUPT_APP=/absolute/path/to/glitchrupt/build/Glitchrupt.app \
  -- /absolute/path/to/uv run --locked --directory /absolute/path/to/glitchrupt glitchrupt mcp
codex mcp list
```

This command changes your Codex MCP configuration; Glitchrupt does not run it for you. Codex also supports project-scoped configuration in trusted projects. The equivalent server table is:

```toml
[mcp_servers.glitchrupt]
command = "/absolute/path/to/uv"
args = ["run", "--locked", "--directory", "/absolute/path/to/glitchrupt", "glitchrupt", "mcp"]
env = { GLITCHRUPT_APP = "/absolute/path/to/glitchrupt/build/Glitchrupt.app" }
```

Use the Codex client's MCP settings to confirm the connection, or `/mcp` in the CLI. Local Codex clients share the host's MCP configuration. See [official MCP setup](https://developers.openai.com/codex/mcp).

The six tools are `glitchrupt_status`, `glitchrupt_variants`, `glitchrupt_signal`, `glitchrupt_wait_for_approval`, `glitchrupt_resolve_approval`, and `glitchrupt_pending_approvals`.

Start with “Use Glitchrupt to show a windowed preview of Fracture.” A normal signal is one cue. An approval wait is a fixed **600 ms + 200 ms gap + 600 ms** pair and repeats every **15 minutes** while registered. The agent must resolve the same stable key as soon as the user responds or the task becomes unblocked, whichever happens first (including cancellation). See [approval tools and lifecycle](approval-alerts.md).

## MCP-first input requests

Hooks are optional. An agent can call `glitchrupt_wait_for_approval` before any request for input: a question, preference, clarification, approval, or required action, even while independent work continues. It calls `glitchrupt_resolve_approval` with the same key immediately when the user responds or that input is no longer needed. The native app owns the timer; no model wakeup is needed every fifteen minutes.

MCP setup and hook trust are separate. A connected MCP server works without trusting the optional hooks. The tradeoff is that a model suspended inside a tool cannot make an extra MCP call when a new runtime permission prompt appears. Automatic coverage of those prompts requires a verified event connection; the global instruction alone does not provide one.

## Automatic events and trust

[`examples/approval-hooks.json`](../examples/approval-hooks.json) contains advisory command hooks for `PermissionRequest`, `PostToolUse`, `Stop`, `SessionEnd`, `Interrupt`, and `UserPromptSubmit`. Replace its portable paths, merge it with existing hooks, and review/trust the exact definitions in Codex (`/hooks` in the CLI). Existing hook definitions and trust records must be preserved. Reload the MCP connection after setup. [Official hook behavior](https://learn.chatgpt.com/docs/hooks).

The command adapter emits only benign `{}` JSON and never grants, rejects, blocks, or changes an approval. **Automatic `PermissionRequest` hooks request the initial double cue only (`repeat:false`).** `PostToolUse` can arrive after a long-running approved tool finishes, so it is not reliable evidence that the user is still waiting to approve it. A precise repeating integration needs an authoritative approval-state connection, such as documented app-server `waitingOnApproval` status and `serverRequest/resolved`; a separate app-server cannot establish access to existing desktop sessions. If that connection is unavailable, automatic repeats stay disabled. [App-server state](https://learn.chatgpt.com/docs/app-server#track-thread-status-changes).

Explicit MCP/CLI waits retain the full recurring policy because the registering agent owns resolution. The optional `AGENTS.md` rule should be reviewed separately before installation. Each chat can register and resolve its own key; the native app handles fifteen-minute timers without an extra monitor chat or recurring model runs. An instruction does not make unsupported platform events observable. Ordinary clarification questions and specialized asynchronous input tools are not guaranteed to emit `PermissionRequest`. See [tool coverage](https://learn.chatgpt.com/docs/hooks#tool-coverage).

## CLI and notification alternatives

Other agents or scripts can skip MCP and run:

```sh
/absolute/path/to/uv run --locked --directory /absolute/path/to/glitchrupt glitchrupt signal --variant classic --duration-ms 600
```

The documented Codex `notify` command currently handles `agent-turn-complete`. It can run a wrapper around this CLI for completion cues, but it is not a general input-waiting event. TUI notification settings can include `approval-requested`, but control terminal notifications rather than an arbitrary Glitchrupt command. [Notification settings](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications).

Prefer MCP for agent-chosen cues and lifecycle hooks for supported automatic events. Avoid scraping chat transcripts or screen pixels to infer pending questions. The source template does not install host settings or trust hooks automatically.

## Verification scope

The local CLI syntax was checked with the current desktop-bundled Codex CLI 0.163.0-alpha.11.2. The older standalone CLI 0.142.4 may not understand settings accepted by the desktop version; use the matching bundled binary rather than changing unrelated settings. The setup and hook examples above match current official documentation, checked 2026-10-25. They are not evidence that the user's existing Codex configuration has been changed, that this chat has the MCP tools connected, or that the example hook has been exercised end to end. Native cue and MCP adapter checks are recorded separately in the project release notes and tests.

## Reviewing hooks with the desktop-bundled CLI

If the standalone `codex` command rejects settings that the desktop app accepts, open Terminal and run:

```sh
/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex
```

Enter `/hooks`, review the six Glitchrupt definitions whose command ends in `glitchrupt hook`, and trust those definitions using Codex's review flow. Preserve unrelated hooks. Then return to the desktop app's Settings → MCP servers, select `glitchrupt`, and restart its connection. A new chat can then discover the six tools. Trust review authorizes the hook definitions; MCP restart refreshes the tool connection. This does not enable hook-only recurring reminders: explicit per-chat wait/resolve calls provide the recurring policy.
