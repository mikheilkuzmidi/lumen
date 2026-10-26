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
