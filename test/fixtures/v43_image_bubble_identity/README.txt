Recorded v0.1.40+41 input, 2026-11-09, customer jd_mbnrscuhukvy.

These screenshots/native OCR files are copied unchanged; SHA-256 and original
immutable metadata are in provenance.json. They show two separate incoming
image messages using the same asset, not two views of one received message:

before-summary (b651c5d1): 11:49:01 sender header, image above the unique
  previous-session summary card.
after-summary (8991c667): 11:49:10 sender header, same image sent again below
  that summary card.
after-summary-reread (2bb28f04): the 11:49:10 message on a later scroll position.
before-summary-reread (aaa5bf4c): an older-message backfill of 11:49:01.

shared-original.jpeg is the exact cached image referenced by original owner15.
Asset reuse remains valid. The two independent incoming business records and
formal-reply coverage must remain separate even when this asset is shared.

The tests also construct same-second and later-sender-header OCR variants to
exercise the identity guards. Those variants are explicitly labelled in test
code; the stored recorded inputs themselves are not edited.
