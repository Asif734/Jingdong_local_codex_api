Recorded input, v0.1.40+41, 2026-11-09

The PNG and .ocr.json files are unmodified copies of native captured evidence.
SHA-256 hashes and immutable capture metadata are in provenance.json.

baseline: f7d56035, before the customer's video; last customer text is
  "i need help with m880" and the seller asks what help is needed.
gray-clipped: f4e69ce6 at 03:44:01.222 UTC, the incoming 11:44:00 video
  is loading and clipped at the bottom of the transcript.
gray-play: 184d21b7 at 03:44:03.383 UTC, that same incoming video is gray
  with a play overlay and its full visible rectangle.
loaded: f109e974 at 03:44:06.231 UTC, that same video has loaded its cover.
after-formal-headerless: bd49149b at 03:46:43.101 UTC, the same video
  remains visible after its sender header has scrolled above the viewport.

The observed failing processing order was gray-play, loaded, gray-clipped.
The first three are one physical customer bubble, not three incoming messages.

Tests use the existing completed_video_fixture/native adapter mock at the
extraction boundary. Cache selection, download, frame extraction, audio and
video-content analysis code are not changed by the media-identity fix.
The direct registrar tests also cover an explicitly constructed two-card
same-second layout and a new-run resend; neither is represented as additional
recorded evidence from this failing run.
