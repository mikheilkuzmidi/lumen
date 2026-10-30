# Recorded runs

Each file holds every answer the Meta Model API gave to one live edit on October 30, 2026: Muse Spark's plan and
verdict, SAM 3.1's masks and checks, and Muse Image's redraw. `--replay` answers the same edit from the file instead of
the API, so it runs with no key, no account and no cost, and makes the same result.

```sh
swift build -c release
.build/release/lumen edit Fixtures/photos/jacket-with-a-hood.jpg "Make his jacket bright yellow" \
  --replay Samples/jacket-bright-yellow.run.json --out yellow.jpg --trace yellow.json
.build/release/lumen edit Fixtures/photos/man-in-denim-jacket-posing.jpg "Dress the man up as a medieval knight" \
  --replay Samples/knight-costume.run.json --out knight.jpg
```

| File | Photo | Instruction | Recorded answers | What the live run cost |
| --- | --- | --- | --- | --- |
| `jacket-bright-yellow.run.json` | `Fixtures/photos/jacket-with-a-hood.jpg` | Make his jacket bright yellow | 5: plan, select, redraw, check, critique | $0.0417 |
| `knight-costume.run.json` | `Fixtures/photos/man-in-denim-jacket-posing.jpg` | Dress the man up as a medieval knight | 6: plan, select the man, his face and his head, redraw, critique | $0.0470 |

Everything Lumen does on the Mac between those answers runs again for real: the masks are decoded, fitted and grown,
the redraw is checked and composited, and the critic's measurements are taken. Replayed on this Mac, the jacket came out
byte for byte the same as the live run, and the knight within 2 of 255 in any channel.

A replay follows the recorded run. Given another photo or instruction, it says so, and stops with an error where the run
asks for an answer that wasn't recorded. Record your own with `--record run.json` on a live edit.

The answers contain no key and no account details: only each request's own id. They are under the same terms as the
fixtures they edit (CC0), and Muse Image's redraws in them are Meta's model output.
