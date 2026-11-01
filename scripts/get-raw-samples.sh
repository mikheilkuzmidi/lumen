#!/bin/bash
set -euo pipefail

# Downloads four public-domain (CC0) camera RAW photos from raw.pixls.us into Fixtures/raw/, to try Lumen on RAW:
#   lumen edit Fixtures/raw/iphone-12-pro-lake.dng "Make the sky a warm sunset"
# Each file is checked against the SHA-256 the repository publishes, and its listing is checked to still say CC0.
# About 90 MB in all. Fixtures/raw/ is not tracked by git.

cd "$(dirname "$0")/.."
destination="Fixtures/raw"
mkdir -p "$destination"
index="$(mktemp)"
trap 'rm -f "$index"' EXIT
curl -fsSL 'https://raw.pixls.us/json/getrepository.php?set=all' -o "$index"

# local name | file name on raw.pixls.us | file id | SHA-256
samples='sony-a7-iii-trees.arw|Sony - ILCE-7M3 - 14bit 14bit compressed (3:2).ARW|2414|250784580ea527442c09004417bb0eead484f2bf3ee8f9121a776ac65bb50d0f
canon-eos-r6-clay-figures.cr3|Canon - EOS R6 - 3:2.CR3|4660|4775df76433b1e5844bc7a42b95d93efc8438c0a4cd9681e120e23fe3e3007e8
nikon-z6-still-life.nef|Nikon - Z 6 - 14bit 14bit compressed (3:2).NEF|3581|8ca94584578b35a422744c1a610174ce37df0691588edfdecaec3111b3fbbb02
iphone-12-pro-lake.dng|Apple - iPhone 12 Pro - 8bit (4:3).DNG|4264|e91e77a4533ed7cce551d83330676ea5c47dd5e55fb38adda7819366afdbdfc2'

while IFS='|' read -r name remote id sha; do
    target="$destination/$name"
    # The listing row for this file must carry the CC0 dedication.
    if ! python3 -I - "$index" "$remote" <<'PY'
import json, sys
rows = json.load(open(sys.argv[1]))["data"]
name = sys.argv[2]
sys.exit(0 if any(name in str(r[7]) and "publicdomain/zero" in str(r[5]) for r in rows) else 1)
PY
    then
        printf '%s is no longer listed as CC0 on raw.pixls.us; skipped.\n' "$remote" >&2
        continue
    fi
    if [[ -f "$target" ]] && [[ "$(shasum -a 256 "$target" | cut -d' ' -f1)" == "$sha" ]]; then
        printf 'Already here: %s\n' "$target"
        continue
    fi
    url="https://raw.pixls.us/getfile.php/$id/nice/$(python3 -I -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1]))' "$remote")"
    printf 'Downloading %s\n' "$name"
    curl -fsSL "$url" -o "$target.part"
    if [[ "$(shasum -a 256 "$target.part" | cut -d' ' -f1)" != "$sha" ]]; then
        rm -f "$target.part"
        printf 'Checksum mismatch for %s; run the script again.\n' "$name" >&2
        exit 1
    fi
    mv "$target.part" "$target"
done <<< "$samples"
printf 'RAW samples in %s. Their sources and licenses are listed in docs/fixtures.md.\n' "$destination"
