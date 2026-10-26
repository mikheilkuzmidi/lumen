# The lumen command

Build with `swift build`, then use `.build/debug/lumen` (or `swift run lumen`). Live edits use your own `META_API_KEY` and model calls consume account credit. Dry runs and the package tests need no key and make no model calls.

```sh
export META_API_KEY='your-key'
lumen edit photos/coat.jpg "Turn his coat navy"
lumen edit photos/coat.jpg "Turn his coat navy" \
  --area 0.2,0.1,0.5,0.8 --out navy.png --trace navy.trace.json
```

The default result is `coat-lumen.jpg` beside the original. Output extensions select the encoding: `.jpg` and `.jpeg` write JPEG, `.png` writes PNG. The original stays untouched, and using it as the output or trace is rejected. The destination directory must already exist for an edit.

| Option | Default | Meaning |
| --- | --- | --- |
| `--area x,y,w,h` | Whole photo | A search boundary in normalised coordinates from the top-left. Width and height must be positive; all edges must lie inside the photo. |
| `--backend meta\|glimmer\|spark-open` | `meta` | Who plans and checks: Muse Spark through the Meta API, Muse Glimmer on this Mac (a running llama-server at `LUMEN_GLIMMER_URL`, or one Lumen starts), or Muse Spark Open on a provider (`SPARK_OPEN_BASE_URL`, `SPARK_OPEN_API_KEY`). SAM 3.1 and Muse Image always use `META_API_KEY`. See [open-weights.md](open-weights.md). |
| `--out <file>` | `<photo name>-lumen.jpg` | Full-size result, including any planned crop. |
| `--trace <file.json>` | No trace file | JSON record written after the result. |
| `--max-steps N` | `12` | Attempted steps across all plans, including select and finish. Zero skips models. |
| `--max-revisions N` | `2` | Additional plans the critic may request. Zero still allows the first critique. |
| `--preview N` | `1536` | Long edge seen by the planner, critic and selection model. Region redraws use crops up to 2048 pixels. Export remains full size. |

Progress prints the plan summary, completed selections and changes with model timings, the critic's verdict and notes, and the reason the edit finished. Colour is used only when stdout is a terminal. Selection counts describe the merged region retained by the agent. Redirected output has one plain-text line per reported event.

Missing keys, unavailable backends and other failures exit nonzero with the error message. Step failures retained by the agent also make the command exit nonzero, even when later steps succeed. Completed layers can still be exported after a model failure. Ctrl-C cancels the active edit and stops an evaluation before its next case. When possible, an interrupted edit still writes its trace.

## Evaluation

```sh
lumen eval Fixtures/instructions.json --out results --dry-run
lumen eval Fixtures/instructions.json --out results --only jacket-with-a-hood
lumen eval Fixtures/instructions.json --out results --max-steps 10 --max-revisions 1
```

Use only photos you have permission to edit. The input is an object with a `cases` array:

```json
{
  "cases": [
    {"photo": "photos/coat.jpg", "instruction": "Make the coat navy"},
    {"name": "coat-green", "photo": "photos/coat.jpg", "instruction": "Make the coat green"}
  ]
}
```

Photo paths resolve relative to the cases file. Names default to the photo filename without its extension; repeated default names receive `-2`, `-3`, and so on. An optional `name` gives a case a stable output name. Explicit names must be unique filenames. `--only` matches the resulting case name exactly.

Cases run one at a time. The runner creates the output folder and writes, for each case:

- `<name>.jpg`: the full-size result, or the layers completed before a failure.
- `<name>.trace.json`: the full trace, including failures.
- `<name>.compare.jpg`: original on the left, result on the right, 1600 pixels wide. Photos retain their aspect ratios, with black padding when needed.

`summary.md` is updated after each case. Its table includes the instruction, applied layers, revisions, final critic verdict, total model time for plan/select/redraw/critique, model call count, failure and an empty `Judged` column. Failed model calls count toward the stage totals and call count. Remove calls count as redraws. A case that finishes before critique is marked `Not critiqued`. Failure details remain visible even when the final critic is satisfied. If a photo cannot be opened or a result cannot be written, its image and comparison may be absent. Other cases continue; any failed case makes the command exit nonzero.

Evaluation accepts the same backend, area, step, revision and preview options as edit. `--dry-run` lists cases and the model stages they could invoke without opening photos, creating output files or requiring credentials. Exact selection, redraw and critique counts depend on the plan and results, so dry runs describe conditional calls rather than inventing a fixed count.

## Trace format

The JSON contains `instruction`, `backend`, `modelIDs` (planner, segmenter, generator), `events` (every shared `TraceEvent` in order), `plans`, `critiques`, `layerLabels`, `stepsApplied`, `revisions`, `exported` and `totalTime` in seconds. Optional `finalReason` and `failure` fields appear when available. Event dates use ISO 8601; event durations are seconds. Plans include the initial checked plan and each checked revision actually entered, while critiques retain the critic's original proposed steps. A trace stores layer labels, not the layer assets needed to reopen a document.
