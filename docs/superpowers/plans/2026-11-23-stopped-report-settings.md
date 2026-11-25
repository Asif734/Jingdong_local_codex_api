# Stopped run diagnostic report and runtime settings

Goal: export an independently readable stopped-run report on Macs without Codex, and expose locked-per-run response/transfer controls without changing capture/delivery logic.

- [x] Persist validated settings: holding delay 20–500 seconds (default50), repeated transfer request threshold2–20 (default4). Apply immutable snapshot before run starts; all relevant clocks and intent gates consume that snapshot.
- [x] Add compact settings controls and export action; disable settings while starting/running/stopping/exporting. Enable export only after completed stop. Hide inline exception/handoff diagnostic details; preserve underlying diagnostic recording.
- [x] Export canonical messages and state, per-message processing evidence with explicit condition/actual/threshold, bounded relevant files, HTML and JSON. Treat missing evidence as unknown, not guessed root cause. Avoid credentials and job payloads.
- [x] Add structured diagnostics at crop/background/cache matching gates, without changing those algorithms.
- [x] Verify settings bounds/locking, timeline/report correlation, media diagnostics and existing send/receipt identity tests. Build a separately versioned app and verify version/signature; do not start live customer tests.

Implementation uses current Flutter/Dart and Swift architecture. Existing dirty work is preserved; no new DB migration solely for settings or reporting.

Validation: stopped-run export click generates a ZIP in the selected directory; direct/receipt/API tests122 pass; timing/intent/report/control tests167 pass; final drain/report/direct tests31 pass. Release0.1.95+96 built, final signing/package verification recorded separately. Native XCTest target still has pre-existing missing-symbol fixtures; production Swift release build succeeds. Historical full-suite baseline failures are not part of this change.
