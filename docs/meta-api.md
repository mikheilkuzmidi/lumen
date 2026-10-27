# Meta Model API: what Lumen relies on

Public facts from Meta's documentation, as of October 26, 2026. The base URL is `https://api.meta.ai/v1`. Each request carries `Authorization: Bearer <key>`, where the key is the user's own Meta API key.

## Muse Spark: planning and critique

- **Model:** `muse-spark-1.3`. It takes text and images and supports structured output.
- **Endpoint:** Lumen calls the OpenAI-compatible `POST /chat/completions`.
  - Images are sent as `image_url` content parts with `data:` URLs.
  - The schema goes in `response_format: { "type": "json_schema", "json_schema": { "name": "...", "schema": {...}, "strict": true } }`.
  - Hosting providers serving Muse Spark Open speak the same protocol.
- **Watch out:** on `/responses` the parameter is `text.format`. A `response_format` sent there is accepted but ignored.
- **Strict schemas:**
  - the root is a plain object;
  - no `oneOf` or `allOf`; `anyOf` is allowed below the root;
  - every object has `additionalProperties: false`, and `required` lists every property;
  - optional values are therefore nullable types, and decoding must accept `null` for them;
  - no recursion; nesting depth is at most 10.

Sources: [structured output](https://dev.meta.ai/docs/structured-output), [Responses API](https://dev.meta.ai/docs/protocols/responses), [models](https://dev.meta.ai/docs/models).

## SAM 3.1: selection

- **Model:** `sam-3.1`, called with `POST /responses` and `"stream": true`.
- **Request:** the `input_text` is either a noun phrase (`"red coat"`) or object prompts, never both.
  - Object prompts, image only: `<0f>1<|box;x1=10;y1=20;x2=39;y2=59;w=640;h=480|>-<|point;x=25;y=30;w=640;h=480|>`.
  - Coordinates are pixels of the image as displayed. `x2` and `y2` are inclusive.
  - A point prefixed with `-` is negative.
  - Every token carries the image's `w` and `h`.
- **Streamed answer:** `response.output_text.delta` events build one line per frame. For an image there is one line, starting with `<0f>`.
  - Each record is an object id, then a `<|box;x1=..;y1=..;x2=..;y2=..;w=..;h=..|>` token and a `<|mask;x=0;y=0;data=H,W,<payload>|>` token, in either order.
  - Records may be separated by commas.
  - With `metadata.include_confidence = "true"`, the tokens may carry `c` from 0 to 1.
  - Unknown tokens and fields are ignored.
  - Zero matches is an empty answer, not an error.
- **Box:** inclusive source pixels. As a normalised rect, right is `x2 + 1` and bottom is `y2 + 1`.
- **Mask:** `data` is `height,width,payload`. The raster is smaller than the photo and covers the box.
  - The payload's first character is the encoding: `~` lossless (the default) or `!` one-bit (`metadata.mask_encoding = "one_bit"`).
  - The rest is base85 over the alphabet `!#$%&'()*+-./0123456789:=?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[]^_\`abcdefghijklmnopqrstuvwxyz{`.
  - It starts with a five-digit length prefix, then an arithmetic-coded body. Lossless coverage is thresholded at 129.

The body's arithmetic coder isn't described in the documentation; it is defined by Meta's reference parser (`python/src/meta_sam_parser/_mask_codec.py` in [meta-models/meta-sam](https://github.com/meta-models/meta-sam)), which is under the SAM License. Lumen's decoder is a port of that file and lives in its own target, `LumenSAMMask`, under the SAM License with a copy of it. The rest of Lumen stays Apache-2.0.

Source: [SAM 3 text format](https://github.com/meta-models/meta-sam/blob/main/protocol/sam3.md), [reading segmentation output](https://dev.meta.ai/docs/sam/reading-segmentation).

## Muse Image: redrawing a region

- **Model:** `muse-image-1.0`, called with `POST /images/edits` and a JSON body: `{ "model", "prompt", "images": [{ "image_url": "data:..." }], "n": 1, "output_format": "png", "response_format": "b64_json" }`.
- **Answer:** the image is in `data[0].b64_json`.
- **Masks:** the endpoint takes no mask. Lumen sends the region's crop and composites the result back through the region's mask itself.
- **Speed:** each call took 12–23 s in earlier measurements, once 73 s, so timeouts must allow for it.

Source: [edit image](https://dev.meta.ai/docs/api-reference/images/edit-image).

## Errors

- HTTP 402: the account has no credit.
- HTTP 429: rate limited; honour `retry-after`.
- A refusal comes back as a refusal content part or a refusal event in a stream.

## Measured on October 26, 2026

One run each on CC0 fixtures, with the user's own key. These are single measurements, not benchmarks.

- **Muse Spark, a plan (one image, strict schema):** HTTP 200 in 6.2–7.7 s. It used about 1,000 reasoning tokens out of 1,144 completion tokens; the answer followed the schema exactly.
- **Muse Spark, a critique (before and after):** 8.0 s.
- **SAM 3.1, "jacket" on 512 × 768 and on 854 × 1280 photos:** HTTP 200 in 1.5–2.9 s. One record with confidence 0.79–0.82. The mask raster had exactly the box's size (for example 463 × 241 for a 241 × 463 box), lossless encoding.
- **Muse Image, redrawing a 0.62 × 0.78 crop of the photo:** 10.4–23.9 s.
- **A complete edit ("Make his jacket bright yellow"):** plan, select, redraw and check took 27 s.

## Muse Spark: library review and planning

`MetaBatchPlanner` uses two structured `POST /chat/completions` calls with the configured planning model
(`muse-spark-1.3` by default):

- **Review:** up to 20 photos appear in one five-column JPEG contact sheet, with 256-pixel cells numbered
  from left to right, top to bottom. Compact JSON supplies each number's sharpness, exposure, shadow and
  highlight clipping, and nullable tilt, alongside the optional instruction. The strict `batch_review`
  response contains `photos`, each with `number`, `misfire`, nullable `misfireReason`, `quality`,
  `description`, `group` and `matchesInstruction`. Numbers map back to the request's photo ids in their
  original order; missing, duplicate or unknown numbers are rejected.
- **Plan:** text JSON supplies the instruction, numbered reviews (`number`, `description`, `group`) and
  answers keyed by question id, without images. The strict `batch_plan` response contains `summary`,
  `groups` (`id`, `title`, photo numbers and a nullable per-photo `instruction`) and `questions`
  (`id`, `question`, two to four `options`, a zero-based `recommended` index and affected group ids).
  Questions are reserved for personal choices; once all choices are answered the questions array is empty.

Both schemas use an object root, reject additional properties and require every property, with optional
values represented by null. Both calls use the same response decoding and error mapping as `MetaPlanner`.

## Cost accounting

Standard pay-as-you-go prices, recorded **October 26, 2026**, in US dollars:

| Model | Input / million tokens | Cached input / million tokens | Output / million tokens | Per image |
| --- | ---: | ---: | ---: | ---: |
| `muse-spark-1.3` | $1.25 | $0.15 | $4.25 | |
| `muse-wonder-1.0` | $4.00 | $0.20 | $20.00 | |
| `muse-image-1.0` | | | | $0.01 successfully returned |
| `sam-3.1` | | | | $0.0025 ($2.50 / 1,000) |

Source: [Meta pricing and rate limits](https://dev.meta.ai/docs/pricing-rate-limits).
The versioned prices live in `MetaPricing.prices` in LumenMeta; estimates use that same table.

Chat completions report `usage.prompt_tokens`, `usage.completion_tokens` and
`usage.prompt_tokens_details.cached_tokens`. Lumen subtracts cached input from total input before
applying the input rate, then adds cached input and output charges. Reasoning tokens are already
included in completion tokens and are never charged twice. Missing cached-token details mean zero
cached tokens. Usage is retained even if the answer is refused or cannot be decoded as a plan.

Every model call's trace carries optional `cost` (USD), `inputTokens`, `cachedInputTokens` and
`outputTokens`. A task-scoped `ModelUsageReporting` hook lets clients report to the agent without
changing the planner, segmenter or generator protocols. Each concurrent call has its own collector.
Muse Image also retains `usage.input_tokens` and `usage.output_tokens` for reference, without
adding a token charge ([response shape](https://dev.meta.ai/docs/image-generation#response-shape)).
SAM charges once for a completed image request, including a search with no matches. Muse Image
charges for successfully decoded returned images; failed generations cost zero. Retries and redraw
checks have their own call traces and charges, even when their layers are later removed.

Unknown models retain token counts but have no price. Missing usage has no inferred token charge.
Open-weight planners record no price, even when a provider's model ID matches a priced Meta model;
provider bills are outside Lumen's total. Totals sum known charges and can therefore be incomplete
when a model or response has no known price. They are a usage record, not an account invoice.

Batch totals include shared review and planning as well as each photo's model calls, once each.
Cost per photo divides that total by all photos in the batch, including flagged or failed photos.
A photo result's own `cost` excludes shared calls. For estimates, the batch uses the average measured
edit charge of completed, nonfailed photos when available. Otherwise each edit pass assumes two
Spark calls with about 3,000 input and 1,000 output tokens each, no cached tokens, two SAM images
and one Muse Image image: **$0.031 per edited photo**. With an open-weight planner the planning
charge is omitted, giving **$0.015**. Low-quality photos receiving both an improvement pass and the
instruction count as two edit passes. Auto and straightening run locally and add no model charge.
Approval shows only the estimated remaining cost; review and planning charges already incurred
remain in the running total. Estimates do not reserve credit or guarantee a final bill.

## Spending less

Measured on October 26, 2026:

| Measure | Result |
| --- | --- |
| A photo's input tokens in Muse Spark | About 1,940 at 1536 px, 860 at 1024 px and 480 at 768 px (the same photo, the same question). |
| The planner and critic at 1024 px | The jacket and the near cup were both met on the first plan; Spark's input fell from 3,414 to 2,928 tokens for the plan and from 5,112 to 4,140 for the check on these 1280 px fixtures. Larger photos save the full 1,080 tokens a photo. |
| Prompt caching | An identical plan request was once served 3,313 of 3,414 tokens from the cache ($0.0034 instead of $0.0081). Five other repeats, and three calls sharing a 2,541-token opening, got none. The cache is opportunistic, so nothing counts on it. |

What Lumen does with this:

- **Planner and critic at 1024 px.** SAM still selects at 1536 px, where detail decides how well a mask fits (`AgentConfiguration.previewLongEdge` and `selectionLongEdge`).
- **What stays the same goes first.** The rules, then the photo (for a check, the Before photo); what changes (the instruction, the steps done, the layers) goes last. When the cache does apply, it can serve the longest part.
- **The same search is not paid for twice.** `CachingSegmenter` answers a repeated SAM request (the same picture and the same prompt) from memory, reporting no usage.
