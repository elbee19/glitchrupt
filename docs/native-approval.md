# Native pending-approval alerts

Glitchrupt owns the reminder timer in its resident menu-bar process. The MCP
subprocess may stop after registering an approval. Quitting Glitchrupt clears
all pending approvals; they are deliberately not restored on launch.

A `wait` request registers a bounded local key, immediately returns `waiting`,
and schedules the first alert. Each alert uses two complete 600 ms animations
with a 200 ms gap. The desktop is restored during the gap. Both bursts reuse
one in-memory snapshot per display, avoiding capture latency in the gap. The
whole pair is one alert for the five-second shared cooldown. These are nominal
animation timings; macOS frame scheduling can add small timing variation.

The optional internal `repeat` flag defaults to true. Repeating entries remain until resolved. One-shot entries (`repeat:false`, used by the advisory hook) are removed after completion, suppression, cancellation, or failure and cannot be claimed again. New registrations during an approval pair or its five-second cooldown share that episode and deadline instead of queueing another pair.

Keys are case-sensitive and use `[A-Za-z0-9._:-]{1,160}`. At most 256 approvals
may be pending. Re-registering a key leaves its settings and deadline intact
and does not issue another immediate alert. `resolve` accepts exactly one key
or one session prefix. `pending` reports remaining milliseconds and the latest
alert status. `status` also includes `pending_count`.

The pure `ApprovalRegistry` uses caller-supplied monotonic uptime. Once due,
all currently due keys become one alert group, using the earliest due key's
sound and preview settings. Their next deadline is 900 seconds from this
attempt, rather than from an old missed deadline. There is no catch-up after
sleep or a stalled process. Busy playback and cooldown defer the same group;
they do not enqueue additional effects. A paused, permission-blocked, or Reduce
Motion-suppressed repeating attempt records its suppression and schedules its next
attempt 900 seconds later. One-shot entries are removed after suppression. Resolving every key in a group suppresses its second
burst if that burst has not started. Muting agent cues also suppresses the
second burst. Changing Reduce Motion before the second desktop burst suppresses
it. Resolution cannot undo a burst that has already appeared.

Use the Glitchrupt menu to preview an approval pair inside the tester, see the
pending approval count, clear pending reminders, pause all agent cues, or quit.
The existing sound checkbox controls the pair's sound as well. The tester
preview remains usable while agent cues are paused. Preview effects do not
require Screen Recording permission.

## Verification

Run the deterministic state-machine tests without waiting fifteen minutes:

```sh
xcrun swiftc -swift-version 5 -warnings-as-errors \
  Sources/ApprovalRegistry.swift tests/native/ApprovalRegistryTests.swift \
  -o /tmp/glitchrupt-approval-registry-tests
/tmp/glitchrupt-approval-registry-tests
```

The tests cover duplicate registration, settings/deadline preservation, due
boundaries, coalescing, suppression status, exact and prefix resolution,
second-burst cancellation eligibility, long-gap catch-up prevention, remaining
time reporting, and clearing state. Native source compilation is a separate
build check; these state tests do not capture or alter the desktop.
