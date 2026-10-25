# Glitchrupt agent guidance

- Swift sources in Sources/ own the renderer, audio, desktop permissions,
  menu-bar controls, and local request handling.
- Python in src/glitchrupt/ owns the CLI and stdio MCP adapter.
- Both interfaces use the request contract in docs/architecture.md.
- Reuse the same cue path for manual tests and agent requests.
- Sound IDs: classic, fracture, brownout, arc, stutter.
- Generate audio with python3 scripts/generate_sounds.py.
- Build the Mac app with ./scripts/build.sh.
- Run Python checks with uv run --locked pytest -q.
- Verify native resources with the build's --verify-sounds option.
- Keep stdout protocol-clean in MCP mode.
- Never commit reference-film audio, personal logs, local paths, or captures.
- Agent calls must respect pause, cooldown, input bounds, and Reduce Motion.
- Public distribution needs a source/package check and signing review.
- Do not publish or install global agent configuration without user scope.
