#!/bin/bash
# Converts typographic quotes (a Swift compile hazard) to ASCII quotes and
# normalizes non-breaking spaces in all Swift sources.
cd "$(dirname "$0")"
find Sources Tests -type f -name "*.swift" -print0 | xargs -0 perl -CSD -Mutf8 -pi -e 's/\x{2018}|\x{2019}/\x27/g; s/\x{201C}|\x{201D}/\x22/g; s/\x{00A0}/ /g;'
grep -rlP '[\x{2018}\x{2019}\x{201C}\x{201D}\x{00A0}]' Sources Tests || echo NO_SMART_QUOTES_LEFT
