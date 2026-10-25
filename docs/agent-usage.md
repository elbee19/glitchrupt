# Glitchrupt for agents

Glitchrupt exposes five original digital-crackle cues through a local CLI and three MCP tools. A single macOS app owns capture permission, sound playback, the overlay, pause control, and the shared cooldown. No HTTP server, network service, API key, screen-image transfer, or chat-content input is involved. This package does not monitor waiting chats; connect a host's notification event later under an explicit user policy.

## Local setup

Build the native app using the project build script, then from the project root:

```sh
uv sync --locked
uv run --locked glitchrupt list
uv run --locked glitchrupt status
uv run --locked glitchrupt app
```

Use `GLITCHRUPT_APP=/absolute/path/to/Glitchrupt.app` when the app is outside the supported locations. Discovery checks `/Applications/Glitchrupt.app`, `~/Applications/Glitchrupt.app`, and this source checkout's `build/Glitchrupt.app`, in that order. An explicitly configured missing app is an error; it does not silently select another app. App paths are trusted process configuration, never tool arguments. Install the Python package with `uv tool install /path/to/glitchrupt` only if you want a persistent CLI; that installation is optional and is not performed by this project.

The native app may require Screen & System Audio Recording permission for the real desktop. The preview window does not capture the desktop. Run `glitchrupt doctor` to receive the current native permission, reduced-motion, pause, busy and cooldown state. `doctor` and `status` both launch the app quietly if needed; `app` opens its desktop tester.

## Commands

```sh
uv run --locked glitchrupt preview --variant fracture --duration-ms 600 --volume 0.28
uv run --locked glitchrupt signal --variant classic --duration-ms 600 --volume 0.28
uv run --locked glitchrupt signal --variant stutter --silent
```

A 600 ms cue plays the entire animation at the corresponding speed. Allowed durations are integer 300–1000 ms; volume is a finite number 0–0.5 (default 0.28). `--silent` suppresses audio. Both desktop and preview requests respect the app's pause, busy, reduced-motion and five-second cooldown rules. Variant IDs are `classic`, `fracture`, `brownout`, `arc`, and `stutter`; `list` describes them.

Every command except `mcp` prints one JSON result to stdout. Exit 0 includes normal suppression (`muted`, `cooldown`, `busy`, `reduce_motion`) as well as successful responses; inspect `status` rather than treating exit 0 as proof a cue played. Exit 1 means operational failure (`error` or `permission_required`); exit 2 means invalid CLI arguments. A `completed` result is returned only after the native effect finishes. A timeout says the outcome is unknown: **never automatically retry** because the first cue may already have run.

## MCP host configuration

Generic stdio configuration (adapt the containing key to your host):

```json
{
  "mcpServers": {
    "glitchrupt": {
      "command": "/absolute/path/to/uv",
      "args": ["run", "--locked", "--directory", "/absolute/path/to/glitchrupt", "glitchrupt", "mcp"],
      "env": {"GLITCHRUPT_APP": "/absolute/path/to/glitchrupt/build/Glitchrupt.app"}
    }
  }
}
```

The project uses official MCP Python SDK 2.3.0, pinned with its dependency graph in `uv.lock`. MCP traffic uses stdio; logs go to stderr. No host or global agent configuration is changed automatically.

Tools:

- `glitchrupt_status({})` checks native readiness without playing an effect.
- `glitchrupt_variants({})` lists the five cues and defaults without launching the app.
- `glitchrupt_signal({"variant":"arc","duration_ms":600,"volume":0.28,"sound":true,"preview":false})` requests exactly one cue.

The signal schema rejects booleans in numeric fields, fractional durations, nonfinite numbers, unknown variants and out-of-range values. There is no arbitrary command, URL, path, sound file, or filesystem input. A tool call can return `error` with a machine-readable `code`; hosts must inspect that status even when MCP transport delivery succeeds. Schema validation errors use MCP's tool-error response.

An example future user policy: “When this chat requires a decision from me, request one `classic` cue. Do not repeat while the same question remains unanswered. Respect app suppression and do not retry on timeout.” This is an example, not an enabled monitor. Read-only tool annotations mean no cue is played; `glitchrupt_status` may start the background app as documented.

## Private bridge and testing

The client atomically writes a 0600 JSON request into `~/Library/Application Support/Glitchrupt/requests/` (0700), then sends a fixed `glitchrupt://request/<UUID>` URL via `/usr/bin/open -g -a <app> ... --args --agent-mode`. It never launches another app instance with `-n`. The app validates requests and atomically replies in the same folder; the client checks the request ID and status, waits up to 15 seconds, and removes its request and response. Requests are not retried. A response arriving after timeout can remain until native stale-file cleanup.

Run meaningful isolated tests with:

```sh
uv run --locked pytest -q
```

Tests cover argument validation, private IPC permissions and cleanup, malformed/mismatched responses, symlink rejection, timeouts without retries, single-instance launch arguments, and actual official SDK tool discovery/calls over both in-process and stdio transports. Native-client injection is a Python test seam; there is no production environment variable that simulates completed effects. Real native desktop capture and playback must be checked separately on a Mac with permission enabled.
