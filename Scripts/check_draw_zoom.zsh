#!/bin/zsh
# Run from a logged-in Air with a review preview already open on Draw.
set -euo pipefail
cd "${0:A:h:h}"
[[ $(hostname) == *Air* || $(hostname) == *air* ]] || { print -u2 'Air only'; exit 2; }
[[ -f /tmp/attic-air-screen.lockdir/owner && $(</tmp/attic-air-screen.lockdir/owner) == zoom-for-good ]] || {
  print -u2 'The zoom-for-good screen lock is required'; exit 2
}
(( $# >= 1 )) || { print -u2 'usage: Scripts/check_draw_zoom.zsh <zoombase|zoomfix> [recording names...]'; exit 2; }
identity=$1; shift
[[ $identity == zoombase || $identity == zoomfix ]] || { print -u2 'Review identity required'; exit 2; }
mkdir -p .build
if [[ ! -x .build/draw-hid-check || Scripts/draw_hid_check.swift -nt .build/draw-hid-check ]]; then
  swiftc Scripts/draw_hid_check.swift -o .build/draw-hid-check
fi
recordings=("$@")
(( ${#recordings} )) || recordings=(pinch-out pinch-in command-scroll-out command-scroll-in)
failed=0
for recording in "${recordings[@]}"; do
  .build/draw-hid-check "$identity" check "$recording" || failed=1
done
exit $failed
