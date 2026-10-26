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

## Models

| Task | Model | Where it runs |
| --- | --- | --- |
| Plan an instruction, judge the result | Muse Spark (`muse-spark-1.3`) | Meta Model API |
| Find regions | SAM 3.1 (`sam-3.1`) | Meta Model API |
| Redraw a region | Muse Image (`muse-image-1.0`) | Meta Model API |
| Plan and judge with open weights | Muse Spark Open | A hosting provider (Baseten or Modal) |
| Plan and judge on this Mac | Muse Glimmer | Locally, if your Mac can hold it |

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
