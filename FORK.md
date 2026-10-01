# Replay screenshot correction

Branch `codex/replay-skip-unsettled-frames` starts at PostHog 3.80.0,
revision `714fd79d8d7496862125dc700946eaccb8a8fce9`.

Screenshot replay skips frames whose mask geometry exceeds the existing drift
budget or cannot be paired between samples. It no longer renders the entire
presentation layer tree with `CALayer.render(in:)`, which can block the main
thread for seconds when rasterizing effects. Settled and bounded-drift frames
retain the existing hierarchy renderer and masks. A replay may retain its last
frame during fast motion. A single pending capture retries once per second with
fresh mask geometry, even when the skipped layout was the final notification.
The retry rechecks recording, foreground state, and the current window before
capturing; it does not queue overlapping renders.

Failed measuring-tick renders are omitted rather than retried with a different
renderer. Native presentation captures still request screen updates. No public
API, masking default, sampling default, or screenshot format is changed.

Five renderer regression tests are in `PostHogScreenshotSafetyTests`. The same
tests run in the consuming app against the resolved SDK so restoring the old
fallback cannot silently pass that app's regression gate. Do not treat this
correction as proof that every hierarchy capture is free of performance hitches.

The consuming app also runs three serial capture-cycle tests for final-layout
recovery, replacement mask owners, and stopping while recovery is pending.
DEBUG-only internal seams expose the real capture entry and its in-flight flag
to those tests; release APIs remain unchanged.
