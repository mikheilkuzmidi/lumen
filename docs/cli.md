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
| `--style <id>` | None | Restyle the person the instruction names: one of `lumen styles` (chad, gigachad, hollywood, beard, older, smile, shades, zombie, skull, tiger, glam, glitter, platinum, vampire, pirate, costume, athletic, muscular). Only that person is redrawn, with the parts the style needs (an older face's neck and hands, a costume's clothes and hat); for `costume`, name the costume in the instruction. Reshaping and ageing are for adults only. |
| `--effect <id>` | None | Grade with one of `lumen styles`' effects (monoDrama, mainCharacter, vintage, neonNight, redCarpet), with a style or alone. |
| `--preview N` | `1024` | Long edge seen by the planner and critic: Muse Spark reads a 1024 px photo as about 860 input tokens, against about 1,940 at 1536 px. SAM selects at 1536 px; region redraws use crops up to 2048 px. Export remains full size. |

Progress prints the plan summary, completed selections and changes with model timings, the critic's verdict and notes, and the reason the edit finished. Colour is used only when stdout is a terminal. Selection counts describe the merged region retained by the agent. Redirected output has one plain-text line per reported event.

Missing keys, unavailable backends and other failures exit nonzero with the error message. Step failures retained by the agent also make the command exit nonzero, even when later steps succeed. Completed layers can still be exported after a model failure. Ctrl-C cancels the active edit and stops an evaluation before its next case. When possible, an interrupted edit still writes its trace.

## Edit a folder

```sh
lumen batch Fixtures/library "Make everyone's shirts blue" --out results/library
lumen batch Fixtures/library "Make everyone's shirts blue" --out results/library \
  --mode plan --straighten yes --max-calls 150
lumen batch Fixtures/library --out results/library --mode autonomous --concurrency 3
```

`lumen batch <folder> ["instruction"] --out <folder>` reviews the library with Muse Spark, flags misfires, applies automatic tone and colour, and offers to straighten tilted horizons. Low-quality photos get a closer look from their own editing agent. When an instruction is supplied, the library reviewer groups the matching photos and writes each group's edit. Each photo's changes remain separate layers. JPEG, PNG and HEIC files directly inside the folder are included; HEIC exports use `.jpg`. The output folder is created as needed and must be separate from the originals.

| Option | Default | Meaning |
| --- | --- | --- |
| `--mode autonomous\|ask\|plan` | `ask` | `autonomous` takes recommendations without prompting. `ask` pauses for personal choices. `plan` reviews and asks, then shows the plan and estimated remaining model calls before changing photos. |
| `--no-auto` | Auto enabled | Skip automatic tone and colour. |
| `--straighten yes\|no\|ask` | `ask` | Straighten tilted horizons, leave them, or ask once for the library. |
| `--no-flag` | Flag misfires | Include misfires in the editing pass. Flagging normally leaves them out of edits and contact sheets. |
| `--quality 0...1` | `0.5` | Photos reviewed below this quality get an individual improvement pass. |
| `--concurrency N` | `3` | Maximum photos edited at once; must be positive. |
| `--max-calls N` | No limit | Whole-batch model call budget, including review and failed calls. Zero skips models. Edits that cannot fit the remaining reservation are listed as skipped. |
| `--answers file.json` | No file | Question ids mapped to exact option text, used without reading stdin. Invalid option text stops the batch. |
| `--yes` | Ask for approval | Approve a plan automatically; personal-choice questions still follow the mode and answer file. |
| `--backend meta\|glimmer\|spark-open` | `meta` | Per-photo planner and critic. Library review and group planning always use Muse Spark through `MetaBatchPlanner` and require `META_API_KEY`. |

Questions print numbered options with the recommendation marked. Enter accepts it. When stdin is not a terminal, unanswered questions take their recommendations and print that choice. Answers from stdin or a file are recorded as the person's choices; automatic recommendations are recorded separately. For example, a file can contain `{"straighten":"Leave them"}`. Other question ids and option text appear during planning.

In plan mode, `Go ahead? [y/N]` requires `y` or `yes`, including when stdin is redirected. An empty answer, end of input or any other reply declines the plan and exits nonzero without changing photos. Use `--yes` for unattended approval. The estimate is approximate; selections, redraws and revisions determine the actual call count.

Progress reports found and measured counts, compact photo reviews, flags, automatic adjustments, straightening, group plans, named per-photo editing events and a completion counter. Measurements do not print a line per photo.

The output folder contains:

- Exported photos and `<exported name>.lumen.json` sidecars, including unchanged photos and flags. Originals stay untouched.
- `batch-summary.md`: every photo's flag, auto adjustment, straightening, instruction and outcome, followed by questions, answers and their source (`stdin`, `answers file` or `recommendation`).
- `batch-trace.json`: the shared `BatchSummary`, including per-photo results, answers, model calls and duration in seconds. Each answer's `byPerson` distinguishes personal choices from automatic recommendations.
- `contact-before.jpg` and `contact-after.jpg`: matching grids of all unflagged photos in library order, labelled with filenames. An unreadable photo retains a named empty cell. An all-flagged or empty library produces an empty sheet.

A completed batch exits zero even if individual photos fail; failures and budget skips appear in the report. A batch-level failure, declined plan or cancellation exits nonzero. Ctrl-C cancels active model calls and stdin prompts. A failed or cancelled batch may leave photos already exported; final reports and sheets are written only after the agent completes. Reserved report filenames cannot overlap exported photo names or inputs.

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

## Cost

`edit` ends with its known cost in USD and model call count, including calls that failed after reporting
usage. `eval` prints each edit's cost and a final total; `summary.md` includes a Cost column and total.
`batch` prints its total and writes total cost and cost per photo to `batch-summary.md`.
`batch-trace.json` retains library and per-photo call events, including token counts and charges.

Plan mode shows an estimate beside the remaining model calls, such as
`Estimate: About 100 more model calls, about $0.62 USD`. The default is $0.031 per edit pass
($0.015 with open-weight planning); a measured average from completed batch photos takes precedence.
Actual charges use reported usage and the dated [Meta price table and counting rules](meta-api.md#cost-accounting).
Unknown prices and missing token usage contribute no inferred charge, so a total covers known charges.
