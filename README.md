# Lumen

Lumen edits photos from a sentence. You describe the change: "make the sky moodier and turn his coat navy". Lumen plans the steps, finds each region and makes the change. It then looks at its own result and revises it until the instruction is met.

- **Planning and checking:** Muse Spark.
- **Finding things:** SAM 3.1 finds them by name, by a box you draw, or by points.
- **Redrawing:** Muse Image redraws what's inside a region.

Every step is a separate, non-destructive layer. You can turn any of them off, adjust them or undo them, and the original photo is never changed.

Lumen is a Swift package with a command-line tool (`lumen`) and a small Mac app (Lumen Studio).

![Lumen Studio after "Make his jacket bright yellow and the buildings behind him a little warmer": the plan, each step with its model and time, and the result Muse Spark checked](docs/images/studio-finished.jpg)

## What existed before, and what is new

Lumen is new work, started on October 26, 2026 for the Meta AI Developer Hackathon. Everything in this repository was written during the event.

Lumen is also the agent inside Photoeditor, a native macOS photo editor that existed before the hackathon. Photoeditor is closed source and is not part of this repository. Photoeditor uses Lumen through the same public interfaces as Lumen Studio.

## How it works

1. **Plan.** Muse Spark reads the instruction and the photo, with any area you drew, and writes a plan in a strict JSON schema: select, adjust, regenerate, remove, crop, revert, finish. Lumen checks the plan before acting on it: values are clamped and steps that use unknown regions or layers are dropped, each with a note.
2. **Find.** SAM 3.1 looks for each region by name. The planner's box only chooses among what SAM found. When a name finds nothing (SAM finds no "gate" in a street-market photo, only its pillars and roof), Lumen asks again with the planner's box as SAM's own prompt.
3. **Change.**
   - Tone and colour changes are adjustment layers through the region's mask, fitted to the photo's edges with a guided filter.
   - Changes to what something is or looks like are redrawn by Muse Image from a crop around the region. Small crops are upscaled first, because Muse Image keeps their layout better at its own scale.
   - SAM then looks at the redraw: if the object moved or changed size, Lumen redraws once more and keeps the better attempt.
   - The patch is composited through the mask, with the generator's colour drift measured on a ring around the region and taken out.
4. **Check.** Muse Spark compares the result with the photo before the instruction. If something is missing or looks wrong, it writes the next steps; a redraw that went wrong is replaced, not stacked. Each revision with a redraw or a failure is checked again, within a step and revision budget.
5. **Remember.** Follow-ups ("a bit less", "undo that") reuse the regions and layers already made.

Every model call, plan, critique and failure is kept in a trace. [docs/evaluation.md](docs/evaluation.md) has the results on 15 CC0 photos.

## Models

| Task | Model | Where it runs |
| --- | --- | --- |
| Plan an instruction, judge the result | Muse Spark (`muse-spark-1.3`) | Meta Model API |
| Find regions | SAM 3.1 (`sam-3.1`) | Meta Model API |
| Redraw a region | Muse Image (`muse-image-1.0`) | Meta Model API |
| Plan and judge with open weights | Muse Spark Open | A hosting provider (Baseten or Modal) |
| Plan and judge on this Mac | Muse Glimmer | Locally through llama.cpp; measured on an M4 Max with 36 GB: about 33 s to load, 70–90 s per plan or check |

Lumen uses your own Meta API key. Set `META_API_KEY`, or enter it in Lumen Studio, which keeps it in the Keychain. No model weights are included here; each model is used under its own license.

## Build

Requires macOS 26 and Xcode 26.

```sh
swift build
swift test
```

## Use it

- **Lumen Studio:** `scripts/build-studio.sh`, then open `.build/studio/Lumen Studio.app`. See [docs/studio.md](docs/studio.md), including how to open a build that isn't notarized.
- **The command:** `swift build -c release`, then `.build/release/lumen edit photo.jpg "Make the sky moodier"`. See [docs/cli.md](docs/cli.md).
- **Open weights:** see [docs/open-weights.md](docs/open-weights.md).

![Selecting the jacket: SAM 3.1's box drawn on the photo while the plan waits](docs/images/studio-selecting.jpg)

## Layout

- **`LumenCore`:** the edit plan, layers, the agent loop and the model protocols (`Planner`, `Segmenter`, `Generator`, `EditHost`). No networking and no pixels.
- **`LumenMeta`:** Muse Spark, SAM 3.1 and Muse Image through the Meta Model API.
- **`LumenSAMMask`:** decodes SAM 3.1's masks (SAM License).
- **`LumenRender`:** applies layers to a photo with Core Image (`PhotoDocument`).
- **`LumenOpen`:** open-weight planners.
- **`lumen`:** the command-line tool.
- **`LumenStudio`:** the Mac app.

## License

Apache License 2.0, see [LICENSE](LICENSE) and [NOTICE](NOTICE), with one exception. `Sources/LumenSAMMask` ports the mask decoder from Meta's reference SAM parser and is under the [SAM License](Sources/LumenSAMMask/LICENSE).
