#!/bin/bash
# Renders stills of the Launch composition at the given seconds into out/qc/ for review. usage: stills.sh 1.5 6 …
cd "$(dirname "$0")/.."
comp=${COMP:-Launch}
for s in "$@"; do
  f=$(python3 -c "print(round($s*60))")
  npx remotion still src/index.ts "$comp" "out/qc/${comp}-${s}.png" --frame="$f" --log=error >/dev/null 2>&1 &
  while [ "$(jobs -r | wc -l)" -ge 4 ]; do sleep 0.3; done
done
wait
ls out/qc | wc -l
