# Open-weight planners

`LumenOpen` provides two `Planner` implementations. Both delegate planning and critique to `LumenMeta.MetaPlanner`, so they share its system prompts, photo content parts, strict `EditPlan.jsonSchema()` and `Critique.jsonSchema()` formats, decoding and error mapping. Selecting one changes the planner; region selection and redrawing still use the segmenter and generator supplied to `EditAgent`.

## Muse Spark Open on a provider

Deploy Muse Spark Open on Baseten or Modal and obtain the deployment's chat-completion base URL and API key. Lumen appends `/chat/completions`; include `/v1` in the base URL if the provider requires it. No deployment or paid call is made by configuring the planner.

```sh
export SPARK_OPEN_BASE_URL='https://your-provider.example/v1'
export SPARK_OPEN_API_KEY='your-provider-key'
export SPARK_OPEN_MODEL='meta-models/muse-spark-open-1026'
```

The model ID above is the Baseten default when `SPARK_OPEN_MODEL` is absent. For Modal, set `SPARK_OPEN_MODEL` to the ID served by your deployment.

```swift
import LumenOpen

let planner = try HostedSparkOpenPlanner.fromEnvironment()
// Supply planner to EditAgent alongside the photo host, segmenter and generator.
```

Explicit configuration is also available with `HostedSparkOpenPlanner(endpoint:apiKey:modelID:)`. The endpoint is a base URL. A missing URL or key, or an explicitly blank model override, throws `HostedSparkOpenPlanner.ConfigurationError.missingKey` with a message naming all three environment variables. This configuration error is separate from the shared `LumenError.missingKey`, whose existing message refers to the Meta API key. HTTP failures, refusals, invalid answers, timeouts and cancellation retain `MetaPlanner`'s existing errors, including its Meta-specific authentication wording.

## Muse Glimmer on this Mac

Install llama.cpp and fetch the GGUF model and vision projector:

```sh
brew install llama.cpp
scripts/get-glimmer.sh
```

The downloader uses [Meta's Muse Glimmer GGUF repository](https://huggingface.co/meta-models/Muse-Glimmer-30B-GGUF). The model listing recorded in this repository on October 26, 2026 names these Apache-2.0 files:

| File | Listed size |
| --- | --- |
| `Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf` | 16.8 GB |
| `mmproj-Muse-Glimmer-30B-Q4_K_M.gguf` | 1.4 GB |

These are listing sizes, not local measurements. Runtime memory also includes context and server overhead; fit on a particular Mac remains to be measured.

The default directory is `~/Library/Application Support/Lumen/Models/muse-glimmer/`. Set `LUMEN_GLIMMER_DIR` to use another directory, for both the downloader and server. The script prints the license and approximate total size before downloading and refuses to download with less than 25 GiB free on the destination volume. Downloads resume into `.part` files using `curl -C -`. Each finished file is checked against the SHA-256 the repository publishes before it is renamed; a damaged one is deleted. Run the script again after an interrupted transfer. Existing completed files are skipped.

`GlimmerServer` finds `llama-server` on `PATH`, then checks `/opt/homebrew/bin/llama-server`. It launches this command, with each path passed as a separate process argument:

```sh
llama-server -m "$LUMEN_GLIMMER_DIR/Muse-Glimmer-30B-KQuant-17GB-Q4_K_M.gguf" \
  --mmproj "$LUMEN_GLIMMER_DIR/mmproj-Muse-Glimmer-30B-Q4_K_M.gguf" \
  --host 127.0.0.1 --port 8786 -c 16384 -ngl 99 --jinja
```

The command above assumes `LUMEN_GLIMMER_DIR` is set to the model directory. The actor resolves the default directory itself when it is unset.

```swift
import LumenOpen

let server = GlimmerServer()
do {
    let baseURL = try await server.start { message in print(message) }
    let planner = LocalGlimmerPlanner(baseURL: baseURL)
    // Supply planner to EditAgent and await completion of the photo edit here.
    await server.stop()
} catch {
    await server.stop()
    throw error
}
```

Startup reports `Loading Muse Glimmer…` and polls `GET /health` for status 200 for up to 180 seconds. Cancellation, timeout or a failed load cleans up the child. Call `stop()` when edits are done; it terminates and reaps the process, forcing termination if necessary. A missing binary names `brew install llama.cpp`, and missing model files name `scripts/get-glimmer.sh`.

To connect to an already-running server, use `LocalGlimmerPlanner()` for `http://127.0.0.1:8786/v1`, or pass `baseURL:` for a different port. The default request model ID is `muse-glimmer`; `modelID:` overrides it. The local planner sends no authorization header.

The initial response format is the same strict schema wrapper used by `MetaPlanner`. For a 400, 422 or 500 error explicitly reporting a missing `schema` key, the local planner retries once with the full schema directly under `response_format.schema`, keeping `type: json_schema`. Other errors do not trigger a retry. The schema itself, messages and photos are preserved. The [llama-server documentation](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md) describes direct schema placement, while the [server parser](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/server-common.cpp) also documents the nested format in code; exact behavior depends on the installed build. A successful response never triggers a format retry.

## Using it from the command line

```sh
export META_API_KEY=…   # SAM 3.1 and Muse Image still answer through the Meta API
lumen edit photo.jpg "Make his jacket bright yellow" --backend glimmer
```

With `--backend glimmer`, Muse Glimmer plans and checks the edit on this Mac; selection and redrawing still use SAM 3.1 and Muse Image. The command uses a llama-server that already answers at `LUMEN_GLIMMER_URL` (default `http://127.0.0.1:8786/v1`); otherwise it starts one with `GlimmerServer`, prints how long loading took, and stops it when the edit ends.

llama.cpp writes an object's keys in the order the schema lists them. The schema Lumen sends to Glimmer therefore lists a step's `type` first and a plan's `summary` before its steps; with alphabetical keys the model had to write a step's other fields before saying what the step was, and its plans came out unusable.

## Measured on October 26, 2026

One Mac, one photo, single runs: these are observations, not benchmarks.

- **Machine:** Apple M4 Max, 36 GB unified memory, macOS 27.2, Homebrew llama.cpp 0.7.0 (build 11669), context 16,384, all layers on the GPU (`-ngl 99`). Other applications were open: the Mac had 8.3 of 9.2 GB of swap in use and reported 17% memory free during the runs.
- **Files:** the two files above, verified against the published SHA-256 (16,756,683,904 and 1,400,328,928 bytes).
- **Loading:** about 33 s from launch to `GET /health` reporting ready, with the vision projector. The server process's own footprint was 2.0–2.9 GB; the weights are memory-mapped from the 16.8 GB file on top of that.
- **Speed:** prompts were read at about 78 tokens/s and answers written at 9.6–10.1 tokens/s. Glimmer reasons before answering, so each call wrote 350–560 tokens.
- **A complete edit,** "Make his jacket bright yellow" on `jacket-with-a-hood.jpg`:

  | Call | Time | Prompt tokens | Written tokens | Answer |
  | --- | --- | --- | --- | --- |
  | Plan | 72.6 s | 1,377 | 563 | Select the jacket (no redraw step yet) |
  | Critique | 75.6 s | 3,411 | 353 | Not satisfied: the jacket is still black; regenerate it bright yellow |
  | Critique | 85.9 s | 2,912 | 471 | Satisfied |

  SAM 3.1 and Muse Image took 1.6 s, 17.7 s and 3.9 s (the redraw check). The result matched the Muse Spark run of the same instruction, at about 4.5 minutes instead of 27 s.
- **Before the key-order fix,** the same instruction failed: Glimmer's reasoning said to select the jacket and regenerate it, but its constrained answers used the region before selecting it, and every revision was dropped by the plan check.

- **After the plan prompt said a selection changes nothing by itself** (commit 0a2311d), the same instruction run again from the command line: Glimmer's first plan selected the jacket and regenerated it (112.4 s), SAM 3.1 and Muse Image took 1.0 s, 19.7 s and 2.4 s, and one critique (85.5 s) was satisfied. 223 s in all, one critique fewer than before. Lumen started llama-server for the run and stopped it afterwards.
- **In Lumen Studio** (scripted run, "Replace the blue sofa with a green velvet one", before that prompt change): Studio loaded Glimmer itself in 21.6 s (the model file was already in the page cache), and the edit finished in 5 minutes.

So the whole planning loop runs on the Mac with open weights, and it works; on this machine, with other work open, it is slow. Muse Spark remains the default.

## A whole library on Glimmer, October 30, 2026

Lumen Studio's library reviews its contact sheets and plans its groups with the chosen planner. The first run of the 16-photo library in `Fixtures/library` on Glimmer, with no instruction, failed all 16 photos, for three reasons, each fixed:

- **The schema wasn't applied.** Studio put the review's schema directly under `response_format.schema`. llama-server 0.7.0 ignores that form: given a test schema that way, Glimmer answered `{"n":7,"w":"hello"}`; given it nested under `json_schema.schema`, it answered with the schema's keys, in the schema's order. The unconstrained review couldn't be decoded. The library now goes through the same transport as the planner, which sends the nested form and leads each review with the photo's number ([#70](https://github.com/mikheilkuzmidi/lumen/issues/70)).
- **The review ran out of time.** A constrained review of 16 photos ran to 4,560 written tokens: 485 s at 9.4 tokens/s, with Photoeditor's QA sweep sharing the GPU. A review now has 1,200 s and a plan or critique 600 s, where the hosted planners keep 180 s ([#71](https://github.com/mikheilkuzmidi/lumen/issues/71)).
- **One failed review failed every photo in it.** Now those photos are judged by measurement, as with no reviewer, and each notes why; they still get their base pass ([#69](https://github.com/mikheilkuzmidi/lumen/issues/69)).

With the nested schema, the run finished in 22 minutes, all on the Mac at no cost. Glimmer described each photo correctly and flagged both misfires, the shaken frame ("motion blur, subject smeared") and the pocket shot ("severely underexposed near-black frame"). The other 14 got Auto, and the three measured as tilted were straightened. The run's first review attempt hit the 600 s limit then in place, and the retry answered from the cached prompt.

## What was verified

On October 26, 2026, the whole package built and the full `swift test` run passed using Swift 6 strict concurrency. SwiftPM's own sandbox was disabled for this restricted build environment. The existing paid live suite stayed disabled, and the existing pixel-rendering tests skipped where Core Image was unavailable.

The open-planner tests use hand-built chat completions and error envelopes only. They compare both backends' plan and critique bodies against `MetaPlanner` and check model IDs, schemas, image URLs, labels and context. They cover nullable fields, text content parts, refusals, malformed answers, HTTP errors, rate limits, timeout and cancellation, provider environment messages, one schema-key retry and the retry limit. Server tests resolve model directories, search executable paths, build the exact launch arguments and check actionable errors without starting a process. No model endpoint, model download or llama-server process was used for these Swift tests.

The downloader was checked with shell syntax validation and stubbed disk-space and download commands. Those checks exercised the low-space refusal, interrupted download resumption, filenames and completed-file skipping without downloading weights.

Muse Spark Open on a provider has not been run: no hosting credits were used. The Glimmer measurements above are the only live open-weight results.

## Still to measure

- Muse Spark Open on Baseten or Modal, when credits are available: latency, cost from actual usage, and the same fixtures.
- Glimmer on a Mac without memory pressure, and with reasoning turned off, to see how much of the time is the model and how much is this machine.
- Glimmer across all the evaluation fixtures, against Muse Spark.
