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

The default directory is `~/Library/Application Support/Lumen/Models/muse-glimmer/`. Set `LUMEN_GLIMMER_DIR` to use another directory, for both the downloader and server. The script prints the license and approximate total size before downloading and refuses to download with less than 25 GiB free on the destination volume. Downloads resume into `.part` files using `curl -C -`; completed files are renamed to the expected filenames. Run the script again after an interrupted transfer. Existing completed files are skipped.

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

## What was verified

On October 26, 2026, the whole package built and the full `swift test` run passed using Swift 6 strict concurrency. SwiftPM's own sandbox was disabled for this restricted build environment. The existing paid live suite stayed disabled, and the existing pixel-rendering tests skipped where Core Image was unavailable.

The open-planner tests use hand-built chat completions and error envelopes only. They compare both backends' plan and critique bodies against `MetaPlanner` and check model IDs, schemas, image URLs, labels and context. They cover nullable fields, text content parts, refusals, malformed answers, HTTP errors, rate limits, timeout and cancellation, provider environment messages, one schema-key retry and the retry limit. Server tests resolve model directories, search executable paths, build the exact launch arguments and check actionable errors without starting a process. No model endpoint, model download or llama-server process was used for these Swift tests.

The downloader was checked with shell syntax validation and stubbed disk-space and download commands. Those checks exercised the low-space refusal, interrupted download resumption, filenames and completed-file skipping without downloading weights.

Live provider compatibility, model loading, Metal operation and output quality have not been verified. No latency, throughput, memory-use or quality measurements are claimed here.

## What the maintainer will measure

- Record the Mac, unified memory, macOS version, llama.cpp build, model revision and context size, plus the provider deployment and model ID for Spark Open.
- Measure cold startup to health status 200, warm startup and peak memory while loading and answering. Check whether this configuration fits the target Mac without sustained swapping.
- Measure plan and critique latency separately on the repository's photo fixtures. Record any timeout, refusal, schema failure or format fallback, and whether the server actually constrains output to the full schema.
- Compare instruction completion, natural-looking edits and revision counts against Muse Spark using the same fixtures and instructions. Record provider cost from actual usage when credits are available.
- Add dated results and the number of runs here after those checks. Hosting credits and a local weights download are still needed for live verification.
