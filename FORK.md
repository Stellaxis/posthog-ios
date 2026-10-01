# Replay screenshot correction

Branch `codex/replay-skip-unsettled-frames` starts at PostHog 3.80.0,
revision `714fd79d8d7496862125dc700946eaccb8a8fce9`.

Screenshot replay skips frames whose mask geometry exceeds the existing drift
budget or cannot be paired between samples. It no longer renders the entire
presentation layer tree with `CALayer.render(in:)`, which can block the main
thread for seconds when rasterizing effects. Settled and bounded-drift frames
retain the existing hierarchy renderer and masks. A replay may retain its last
frame during fast motion, until another settled capture occurs.

Failed measuring-tick renders are omitted rather than retried with a different
renderer. Native presentation captures still request screen updates. No public
API, masking default, sampling default, or screenshot format is changed.

Five renderer regression tests are in `PostHogScreenshotSafetyTests`. The same
tests run in the consuming app against the resolved SDK so restoring the old
fallback cannot silently pass that app's regression gate. Do not treat this
correction as proof that every hierarchy capture is free of performance hitches.
