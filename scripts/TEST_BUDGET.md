# Optional test spending guard

This is a task-scoped guard for test and capture processes, not an account billing setting. Ordinary Lumen use does not enable it. Use one ledger for every live client participating in a capped task; an unrelated app or arbitrary HTTP client is outside this guard.

Set both variables before launching a test, CLI, Studio, or host app:

```sh
export LUMEN_TEST_BUDGET_HELPER="/absolute/checkout/scripts/test_budget.py"
export LUMEN_TEST_BUDGET_LEDGER="/absolute/task/ledger.json"
```

The helper uses Python 3's standard library, an exclusive `flock`, private file permissions, atomic replace, and `fsync`. Do not reset or delete the ledger during a task. A partial configuration, inaccessible helper, corrupt ledger, unknown provider/model/endpoint, hosted tool loop, or unsupported video request refuses inference. Local loopback services can run; a local gateway must also guard its upstream requests with this same helper and ledger.

Each physical URLSession request reserves before transmission, underneath retries. Bounded output is added only when the guard is enabled. All settled charges plus pending/uncertain maxima must fit $4.50. The remaining $0.50 of the $5 total is an uncertainty buffer, not normal spend capacity. Timeouts, cancellation, incomplete responses, HTTP errors and missing usage keep their full reservations across restart. A reported charge exceeding its quote freezes future requests for reconciliation. Redirects are not automatically followed while guarded.

Prices and model context limits were verified November 2, 2026 from:

- <https://dev.meta.ai/docs/pricing-rate-limits>
- <https://dev.meta.ai/docs/models>

Multimodal chat reserves the entire 1,048,576-token input context at uncached rates plus at most 8192 output tokens. Text-only chat uses its complete UTF-8 JSON byte length plus 8192 template tokens, capped at the documented context. Single image generation and still-image SAM use their published per-image prices. Transcription validates mono 16-bit 16/24kHz WAV, at most ten minutes, and reserves the complete ten-minute cost. Cached-token discounts are conservatively not deducted from settled token charges. These large reservations are intentional; serialize live tests to avoid unnecessary refusals. A refusal is not permission to bypass the guard.

The November 2 pricing page states that transcription audio is "rounded down to whole seconds" at $0.18/hour. Public `MetaTranscriber` billing estimates retain that documented floor. This task ledger deliberately rounds reported milliseconds **up** to whole seconds as a conservative liability: 999ms holds 50 microUSD and 1500ms holds 100 microUSD, versus the published rounded-down amounts of 0 and 50 microUSD. Missing duration keeps the complete reservation. Its `actualMicros` field therefore means a reconciled upper bound, not an invoice; token settlements similarly do not deduct cached-input discounts.

For entirely free QA, additionally set:

```sh
export LUMEN_TEST_BUDGET_DENY_NETWORK=1
```

This refuses provider traffic before a reservation or a request. Recorded transports and local processing need no API access.

Python callers can import `test_budget.py`. Other runtimes send a JSON object on stdin and read `{ "ok": true, "result": ... }` from stdout. Nonzero exit or `ok: false` means stop. The ledger never contains request/response bodies or authorization headers. The `prepare` RPC returns the bounded body to the caller, so do not print or save its stdout in public logs.

Initialize or read a ledger using `{"operation":"summary"}`. A narration client must verify its exact provider's current license, character billing and maximum cost before reserving each attempt with `operation: "reserve"`, a safe `provider`/`model` identifier, and integer `maximumMicros` (one dollar is 1,000,000). This reservation does not authorize a provider call. Allowed bounds contain numeric input/output/image/audio/character/credit/rate quantities and an ISO `priceDate`; never pass narration text or credentials. After confirmed metered usage, use `operation: "settle"`, its reservation ID, integer `actualMicros` rounded upward, and `outcome: "complete"`. For unknown usage or an interrupted attempt, omit `actualMicros` and use the appropriate outcome (`unknown`, `cancelled`, or `network_error`). Uncertain reservations cannot be refunded by a later duplicate settlement.

Offline verification:

```sh
python3 scripts/test_budget_tests.py
swift test --filter testSpendGuard
```

The ledger records an attempt's elapsed time from reservation to settlement. This includes transport, response delivery and guard overhead; it is not an isolated server inference measurement.
