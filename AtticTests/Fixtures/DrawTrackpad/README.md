# Recorded trackpad input

Unmodified consecutive lines from `owner-trackpad-2.jsonl`, recorded on the
Pro over Wave 3 (`9f6a841a`) on 2 Nov 2026 with a listen-only session event
tap. Original SHA-256: `f3df0694282f271501c8d36450d27cfae4f084f345b76588eb3536316f0d8c3d`.

| Fixture | Original lines (inclusive) |
| --- | --- |
| `pinch-out.jsonl` | 178–286 |
| `pinch-in.jsonl` | 315–376 |
| `command-scroll-out.jsonl` | 4554–4786 |
| `command-scroll-in.jsonl` | 6952–7088 |

Keep the CGEvent data, callback order, relative locations and timing intact.
The scroll fixtures include the paired HID 6 gestures and momentum; pinches
include HID 0/4 touch events, the preceding scroll cancellation, and all
magnification phases. CG timestamps can move backwards between the paired
scroll and gesture events; preserve callback order and wait until each
relative deadline rather than sorting the stream.

Hosted tests retarget the events to their own panel and dispatch in-process;
they do not prove WindowServer delivery. The separate Air replay check posts
these recordings at the session event tap. Never post them on the Pro or
construct private gesture/touch payloads by hand: an earlier guessed payload
caused a WindowServer assertion and logged the Air out.
