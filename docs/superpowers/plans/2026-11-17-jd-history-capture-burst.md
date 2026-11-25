# JD history capture burst implementation plan

**Goal:** Capture overlapping history pages without restoring between consecutive screenshots, and yield to scheduled replies between pages.

**Architecture:** Keep verified scroll and snapshot serialized; submit each immutable snapshot to existing background OCR. Retain the last captured page and restore the latest chat once per burst. Native scroll can sample the verified chat viewport while it settles.

- [ ] Exercise incremental scroll, one restore, and resume after reply priority with a database-backed test.
- [ ] Wire general backfill and exact media recovery to bounded bursts.
- [ ] Verify recovery and response checks; build and verify the versioned macOS app.
