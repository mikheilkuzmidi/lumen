# Recorded runs

Each file holds every answer the Meta Model API gave to a recorded live edit: Muse Spark's plan and verdict,
SAM 3.1's masks and checks, and Muse Image's redraw. `--replay` answers the same edit from the file instead of the
API, so it runs with no key, no account and no new provider charge. It applies the current image-processing code;
renderer fixes can intentionally improve the original live output.

```sh
swift build -c release
.build/release/lumen edit Fixtures/photos/jacket-with-a-hood.jpg "Make his jacket bright yellow" \
  --replay Samples/jacket-bright-yellow.run.json --out yellow.jpg --trace yellow.json
.build/release/lumen edit Fixtures/photos/man-in-denim-jacket-posing.jpg "Dress the man up as a medieval knight" \
  --replay Samples/knight-costume.run.json --out knight.jpg
.build/release/lumen edit Fixtures/library/men-laughing-by-green-valley.jpg \
  "Make only the far-right man’s white T-shirt black. Keep the other people, his skin, and the scene unchanged." \
  --replay Samples/white-shirt-black.run.json --out black-shirt.jpg
```

| File | Photo | Recorded | Answers | Recorded usage cost |
| --- | --- | --- | --- | --- |
| `jacket-bright-yellow.run.json` | `Fixtures/photos/jacket-with-a-hood.jpg` | November 2, 2026 | 5: plan, select, redraw, check, critique | $0.043160 |
| `white-shirt-black.run.json` | `Fixtures/library/men-laughing-by-green-valley.jpg` | November 2, 2026 | 5: plan, select, redraw, check, critique | $0.045816 |
| `knight-costume.run.json` | `Fixtures/photos/man-in-denim-jacket-posing.jpg` | October 30, 2026 | 6: plan, select the man, his face and his head, redraw, critique | $0.0470 |

Everything Lumen does on the Mac between those answers runs again for real: the masks are decoded, fitted and grown,
the redraw is checked and composited, and the critic's measurements are taken. The November 2 coat and shirt runs
originally revealed old-color edge residue. They are retained so the current renderer's correction can be reproduced
without another model call. The earlier coat recording remains in `archive/`.

Any API-cost summary printed during replay describes recorded model usage, not a new charge. The recorded model's
critique is also historical; inspect the current image rather than treating that verdict as new model evaluation.

A replay follows the recorded run. Given another photo or instruction, it says so, and stops with an error where the run
asks for an answer that wasn't recorded. Record your own with `--record run.json` on a live edit.

The recordings contain response bodies, response content types, API paths, status codes and request IDs; they contain
no authentication headers or account credentials. The source photographs are permitted CC0 fixtures. Muse Image's
redraws remain model output under the applicable Meta terms; this document does not relicense model output as CC0.
