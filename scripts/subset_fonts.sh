#!/usr/bin/env bash
# Subsets the bundled Inter faces to the scripts this app actually renders.
#
# The upstream Inter TTFs carry every script Inter supports (~320 KB each,
# ~1.6 MB for the five weights). The app ships three locales — en, pt-BR, ru —
# so the vast majority of that never renders and only costs APK size.
#
# Usage:
#   scripts/subset_fonts.sh <directory-with-full-inter-ttfs>
#
# Upstream source: https://github.com/rsms/inter/releases (Inter Desktop /
# static TTFs). Re-download from there when a weight is added or Inter is
# upgraded, then re-run this script — do not commit an unsubsetted face.
#
# Requires fonttools:
#   python3 -m venv .fontenv && .fontenv/bin/pip install fonttools brotli
#   PYFTSUBSET=.fontenv/bin/pyftsubset scripts/subset_fonts.sh <dir>
set -euo pipefail

SOURCE_DIR=${1:?usage: scripts/subset_fonts.sh <directory-with-full-inter-ttfs>}
DEST_DIR=$(cd "$(dirname "$0")/.." && pwd)/packages/capy_ui/assets/fonts
PYFTSUBSET=${PYFTSUBSET:-pyftsubset}

# Blocks the three shipped locales need, plus the symbols the UI composes at
# runtime. Ranges rather than an exact glyph list: strings are formatted at
# runtime (dates, currency, units), so pinning the subset to today's literals
# would break the first time someone adds a string.
#
#   0020-00FF  Basic Latin + Latin-1 Supplement (pt accents, · ° × §)
#   0100-017F  Latin Extended-A
#   0370-03FF  Greek (π appears in chart and geometry captions)
#   0400-04FF  Cyrillic (ru)
#   2000-206F  General Punctuation (– — ' • …)
#   20A0-20BF  Currency symbols (₽, €, ₴ from locale-aware formatting)
#   2100-214F  Letterlike Symbols (№ for ru, ™)
#   2190-21FF  Arrows (→)
#   2200-22FF  Mathematical Operators (− true minus)
UNICODES="U+0020-00FF,U+0100-017F,U+0370-03FF,U+0400-04FF,U+2000-206F"
UNICODES="$UNICODES,U+20A0-20BF,U+2100-214F,U+2190-21FF,U+2200-22FF"

# `tnum`/`pnum` are not in pyftsubset's default feature set, and `AppText`
# applies FontFeature.tabularFigures() to every metric style. Dropping `tnum`
# would make live numbers jitter as digits change width; `pnum` is kept as its
# counterpart so body copy can still ask for proportional figures.
#
# `frac`, `numr` and `dnom` are deliberately not kept: nothing requests them
# and they pull in a separate set of figure glyphs.
FEATURES="calt,ccmp,clig,curs,dist,kern,liga,locl,mark,mkmk,rclt,rlig,rvrn"
FEATURES="$FEATURES,tnum,pnum"

total_before=0
total_after=0

for face in Regular Medium SemiBold Bold ExtraBold; do
  src="$SOURCE_DIR/Inter-$face.ttf"
  dest="$DEST_DIR/Inter-$face.ttf"
  if [ ! -f "$src" ]; then
    echo "missing source face: $src" >&2
    exit 1
  fi

  "$PYFTSUBSET" "$src" \
    --output-file="$dest" \
    --unicodes="$UNICODES" \
    --layout-features="$FEATURES" \
    --name-IDs='*' \
    --notdef-outline \
    --recalc-bounds

  before=$(wc -c <"$src")
  after=$(wc -c <"$dest")
  total_before=$((total_before + before))
  total_after=$((total_after + after))
  printf '%-24s %7d -> %7d bytes\n' "Inter-$face.ttf" "$before" "$after"
done

printf '\ntotal %d -> %d bytes (%d%% of original)\n' \
  "$total_before" "$total_after" $((total_after * 100 / total_before))
