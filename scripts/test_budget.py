#!/usr/bin/env python3
"""Task-only, cross-process test-spend guard. No network calls or secrets in its ledger.

Set LUMEN_TEST_BUDGET_LEDGER to one absolute ledger path and
LUMEN_TEST_BUDGET_HELPER to this file in EVERY test/capture process. Python callers
can import this module; Node/Swift callers use the JSON stdin/stdout RPC below.
All amounts are integer micro-US-dollars. Never delete/reset a live ledger.
"""
from __future__ import annotations

import base64
import contextlib
import datetime
import decimal
import email.parser
import email.policy
import fcntl
import io
import json
import math
import os
from pathlib import Path
import stat
import sys
import tempfile
import urllib.parse
import uuid
import wave

SCHEMA = 1
PLANNED = 4_500_000
HARD = 5_000_000
PRICE_DATE = "2026-11-02"
PRICE_SOURCE = "https://dev.meta.ai/docs/pricing-rate-limits"
CONTEXT = 1_048_576  # https://dev.meta.ai/docs/models (Spark and Wonder)
TOKEN_RATES = {"muse-spark-1.3": (decimal.Decimal("1.25"), decimal.Decimal("4.25")),
               "muse-wonder-1.0": (decimal.Decimal("4"), decimal.Decimal("20"))}


class BudgetError(RuntimeError):
    pass


def integer(value, name, minimum=0):
    if isinstance(value, bool) or not isinstance(value, int) or value < minimum:
        raise BudgetError(f"{name} must be an integer >= {minimum}")
    return value


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat()


def microdollars(dollars):
    return int((decimal.Decimal(str(dollars)) * 1_000_000).to_integral_value(rounding=decimal.ROUND_CEILING))


def liability(entry):
    return entry["actualMicros"] if entry["state"] == "settled" else entry["maximumMicros"]


def validate(ledger):
    if ledger.get("schema") != SCHEMA or ledger.get("plannedMicros") != PLANNED or ledger.get("hardMicros") != HARD:
        raise BudgetError("Unrecognized ledger or modified spending limits; refusing inference")
    if not isinstance(ledger.get("entries"), list):
        raise BudgetError("Invalid ledger entries")
    ids = set()
    for entry in ledger["entries"]:
        if not isinstance(entry, dict) or entry.get("state") not in ("reserved", "uncertain", "settled"):
            raise BudgetError("Invalid ledger entry")
        if not isinstance(entry.get("id"), str) or entry["id"] in ids:
            raise BudgetError("Invalid or duplicate reservation ID")
        ids.add(entry["id"])
        integer(entry.get("maximumMicros"), "maximumMicros", 1)
        if entry["state"] == "settled":
            integer(entry.get("actualMicros"), "actualMicros")
    return ledger


class Ledger:
    def __init__(self, path):
        self.path = Path(path).expanduser()
        if not self.path.is_absolute() or self.path.is_symlink():
            raise BudgetError("The ledger must be an absolute, nonsymlink file path")
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.lock = Path(str(self.path) + ".lock")

    @contextlib.contextmanager
    def transaction(self):
        fd = os.open(self.lock, os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
        try:
            if not stat.S_ISREG(os.fstat(fd).st_mode):
                raise BudgetError("Ledger lock is not a regular file")
            fcntl.flock(fd, fcntl.LOCK_EX)
            if self.path.exists():
                read_fd = os.open(self.path, os.O_RDONLY | os.O_NOFOLLOW)
                with os.fdopen(read_fd) as source:
                    if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                        raise BudgetError("Ledger is not a regular file")
                    try:
                        ledger = validate(json.load(source))
                    except (ValueError, TypeError, KeyError) as error:
                        raise BudgetError("Corrupt ledger; refusing inference") from error
            else:
                ledger = {"schema": SCHEMA, "plannedMicros": PLANNED, "hardMicros": HARD,
                          "createdAt": now(), "frozen": False, "entries": []}
            yield ledger
            validate(ledger)
            temp_fd, temp_name = tempfile.mkstemp(prefix=".budget-", dir=self.path.parent)
            try:
                with os.fdopen(temp_fd, "w") as target:
                    json.dump(ledger, target, sort_keys=True, indent=2, allow_nan=False)
                    target.write("\n")
                    target.flush()
                    os.fsync(target.fileno())
                os.replace(temp_name, self.path)
                directory = os.open(self.path.parent, os.O_RDONLY)
                try:
                    os.fsync(directory)
                finally:
                    os.close(directory)
            finally:
                if os.path.exists(temp_name):
                    os.unlink(temp_name)
        finally:
            os.close(fd)

    def reserve(self, provider, model, maximum_micros, category="test", bounds=None):
        integer(maximum_micros, "maximumMicros", 1)
        # Only identifiers and numeric bounds enter the ledger, never prompts,
        # photos, URLs with queries, voice text, credentials, or response bodies.
        if not all(isinstance(x, str) and 0 < len(x) <= 100 and all(c.isalnum() or c in "-_." for c in x)
                   for x in (provider, model, category)):
            raise BudgetError("Invalid provider, model, or category identifier")
        allowed_bounds = {"inputTokens", "outputTokens", "images", "audioSeconds", "clipSeconds", "characters", "credits", "rateMicrosPer1000"}
        if bounds is not None:
            if not isinstance(bounds, dict):
                raise BudgetError("Invalid quote bounds")
            for key, value in bounds.items():
                if key == "priceDate" and isinstance(value, str):
                    try:
                        datetime.date.fromisoformat(value)
                    except ValueError as error:
                        raise BudgetError("Invalid pricing date") from error
                elif key in allowed_bounds:
                    integer(value, "numeric quote bound")
                else:
                    raise BudgetError("Only numeric quote bounds and a pricing date may enter the ledger")
        with self.transaction() as ledger:
            used = sum(liability(entry) for entry in ledger["entries"])
            if ledger["frozen"] or used + maximum_micros > PLANNED or used > HARD:
                raise BudgetError(f"Test budget refused: liability {used} + reservation {maximum_micros} microUSD exceeds planned cap {PLANNED}, or ledger is frozen")
            identifier = str(uuid.uuid4())
            ledger["entries"].append({"id": identifier, "provider": provider, "model": model,
                                      "category": category, "maximumMicros": maximum_micros,
                                      "state": "reserved", "createdAt": now(), "bounds": bounds or {}})
        return identifier

    def settle(self, identifier, actual_micros=None, outcome="unknown"):
        if actual_micros is not None:
            integer(actual_micros, "actualMicros")
        if outcome not in ("complete", "missing_usage", "http_error", "network_error", "cancelled", "unknown", "stream_error"):
            raise BudgetError("Invalid settlement outcome")
        overrun = False
        with self.transaction() as ledger:
            entry = next((item for item in ledger["entries"] if item["id"] == identifier), None)
            if entry is None or entry["state"] != "reserved":
                raise BudgetError("Unknown or already settled reservation")
            if actual_micros is None:
                entry.update(state="uncertain", outcome=outcome, finishedAt=now())
            else:
                entry.update(state="settled", actualMicros=actual_micros, outcome=outcome, finishedAt=now())
                if actual_micros > entry["maximumMicros"]:
                    # Preserve the real charge and immediately prevent further
                    # requests. The $0.50 buffer is not routine spending money.
                    ledger["frozen"] = True
                    overrun = True
            entry["elapsedMs"] = max(0, (datetime.datetime.fromisoformat(entry["finishedAt"]) - datetime.datetime.fromisoformat(entry["createdAt"])).total_seconds() * 1000)
            if sum(liability(item) for item in ledger["entries"]) > HARD:
                ledger["frozen"] = True
                overrun = True
        if overrun:
            raise BudgetError("Provider usage exceeded the conservative quote; ledger frozen for reconciliation")

    def summary(self):
        with self.transaction() as ledger:
            amounts = {state: sum(liability(e) for e in ledger["entries"] if e["state"] == state)
                       for state in ("settled", "reserved", "uncertain")}
            return {"schema": SCHEMA, "plannedMicros": PLANNED, "hardMicros": HARD,
                    "liabilityMicros": sum(amounts.values()), "frozen": ledger["frozen"],
                    "amountsMicros": amounts, "attempts": len(ledger["entries"])}


def all_objects(value):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from all_objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from all_objects(child)


def quote_request(url, method, body, content_type):
    """Return sanitized/explicitly bounded body and its conservative cost quote.

    Multimodal text requests reserve the ENTIRE documented context at uncached
    input rates, plus the bounded output. No guessed per-image token estimates.
    Text-only JSON is bounded by its UTF-8 byte length plus 8192 template tokens.
    Only supported single-inference endpoints are allowed; hosted tools, videos,
    background calls, unknown models/providers and streaming chat are refused.
    """
    parsed = urllib.parse.urlparse(url)
    if parsed.hostname in ("127.0.0.1", "localhost", "::1"):
        return body, None  # local Glimmer / local gateway; gateway guards upstream
    if parsed.scheme != "https" or parsed.hostname != "api.meta.ai" or parsed.port not in (None, 443) or parsed.username or parsed.password or parsed.query or parsed.fragment:
        raise BudgetError("Unknown provider/URL under the test budget; no request sent")
    if method.upper() != "POST":
        raise BudgetError("Unclassified method under the test budget")
    path = parsed.path
    if path == "/v1/asr/transcribe":
        if not content_type.startswith("multipart/form-data;"):
            raise BudgetError("Transcription requires bounded multipart WAV audio")
        message = email.parser.BytesParser(policy=email.policy.default).parsebytes(
            b"Content-Type: " + content_type.encode("ascii") + b"\r\nMIME-Version: 1.0\r\n\r\n" + body)
        parts = {part.get_param("name", header="content-disposition"): part.get_payload(decode=True)
                 for part in message.iter_parts()}
        request = json.loads(parts.get("request", b"{}"))
        if request.get("model") != "muse-voice-transcribe-1.0" or request.get("audioEncoding") != "WAV":
            raise BudgetError("Unknown transcription model/format")
        with wave.open(io.BytesIO(parts.get("audio", b""))) as audio:
            if audio.getnchannels() != 1 or audio.getsampwidth() != 2 or audio.getframerate() not in (16000, 24000):
                raise BudgetError("Transcription WAV must be mono 16-bit 16/24 kHz")
            seconds = math.ceil(audio.getnframes() / audio.getframerate())
        if not 0 < seconds <= 600 or len(body) > 33_000_000:
            raise BudgetError("Unbounded transcription audio")
        # Reserve the documented ten-minute file limit even for a short WAV.
        # This also protects against differing provider WAV-decoder behavior.
        return body, {"model": request["model"], "maximumMicros": 600 * 50,
                      "bounds": {"audioSeconds": 600, "clipSeconds": seconds, "priceDate": PRICE_DATE}}
    if "application/json" not in content_type:
        raise BudgetError("Unclassified request content type")
    obj = json.loads(body)
    if not isinstance(obj, dict):
        raise BudgetError("Expected a JSON object")
    model = obj.get("model")
    if any(obj.get(k) for k in ("tools", "functions", "background", "previous_response_id", "conversation")):
        raise BudgetError("Tool loops/background/history have unbounded cost")
    objects = list(all_objects(obj))
    if any(item.get("type") in ("input_video", "video_url", "input_audio", "audio", "input_file") or
           any(key in item for key in ("video_url", "video", "audio", "file_id")) for item in objects):
        raise BudgetError("Video/audio/file inference is not classified by this guard")
    if path == "/v1/chat/completions" and model in TOKEN_RATES:
        if obj.get("stream") or obj.get("n", 1) != 1:
            raise BudgetError("Only one nonstreaming chat completion is bounded")
        if "max_tokens" in obj and "max_completion_tokens" in obj:
            raise BudgetError("Conflicting completion limits")
        requested = obj.pop("max_tokens", obj.get("max_completion_tokens", 8192))
        cap = min(integer(requested, "max_completion_tokens", 1), 8192)
        obj["max_completion_tokens"] = cap
        encoded = json.dumps(obj, separators=(",", ":"), ensure_ascii=False).encode()
        has_images = any("image_url" in item or item.get("type") == "input_image" for item in objects)
        input_bound = CONTEXT if has_images else min(CONTEXT, len(encoded) + 8192)
        input_rate, output_rate = TOKEN_RATES[model]
        maximum = int((input_bound * input_rate + cap * output_rate).to_integral_value(rounding=decimal.ROUND_CEILING))
        return encoded, {"model": model, "maximumMicros": maximum,
                         "bounds": {"inputTokens": input_bound, "outputTokens": cap, "priceDate": PRICE_DATE}}
    if path in ("/v1/images/edits", "/v1/images/generations") and model == "muse-image-1.0":
        count = integer(obj.get("n", 1), "image count", 1)
        if count > 4:
            raise BudgetError("At most four images per guarded request")
        obj["n"] = count
        return json.dumps(obj, separators=(",", ":")).encode(), {"model": model, "maximumMicros": count * 10_000,
                         "bounds": {"images": count, "priceDate": PRICE_DATE}}
    if path == "/v1/responses" and model == "sam-3.1":
        image_count = sum(item.get("type") == "input_image" for item in objects)
        if image_count != 1:
            raise BudgetError("Only one SAM still image is currently bounded")
        return body, {"model": model, "maximumMicros": 2500, "bounds": {"images": 1, "priceDate": PRICE_DATE}}
    raise BudgetError("Unknown model or endpoint under the test budget")


def actual_cost(quote, status, body):
    if not 200 <= status < 300:
        return None, "http_error"
    model, bounds = quote["model"], quote["bounds"]
    if model == "sam-3.1":
        # Even a fully read SSE error may have incurred segmentation cost.
        return quote["maximumMicros"], "complete"
    try:
        obj = json.loads(body)
        if model in TOKEN_RATES:
            usage = obj["usage"]
            inputs = integer(usage["prompt_tokens"], "prompt_tokens")
            outputs = integer(usage["completion_tokens"], "completion_tokens")
            # Cached input is deliberately billed at the higher uncached rate
            # in this ledger. This never understates an actual known charge.
            a, b = TOKEN_RATES[model]
            return int((inputs * a + outputs * b).to_integral_value(rounding=decimal.ROUND_CEILING)), "complete"
        if model == "muse-image-1.0":
            images = obj["data"]
            if not isinstance(images, list) or len(images) > bounds["images"]:
                return None, "missing_usage"
            return len(images) * 10_000, "complete"
        if model == "muse-voice-transcribe-1.0":
            seconds = (integer(obj["audioDurationMs"], "audioDurationMs") + 999) // 1000
            if seconds > bounds["audioSeconds"]:
                return None, "missing_usage"
            return seconds * 50, "complete"
    except (ValueError, KeyError, TypeError, BudgetError):
        pass
    return None, "missing_usage"


def rpc(payload):
    operation = payload["operation"]
    if operation == "prepare" and payload.get("denyNetwork") and urllib.parse.urlparse(payload["url"]).hostname not in ("127.0.0.1", "localhost", "::1"):
        # Offline denial precedes even a filesystem/ledger lookup. This makes
        # it safe for an app whose paid ledger lives in a protected directory.
        raise BudgetError("This offline QA run denies provider traffic; no request sent")
    path = payload.get("ledger") or os.environ.get("LUMEN_TEST_BUDGET_LEDGER")
    if not path:
        raise BudgetError("LUMEN_TEST_BUDGET_LEDGER is required")
    ledger = Ledger(path)
    if operation == "summary":
        return ledger.summary()
    if operation == "reserve":
        # Narration caller supplies a verified maximum before EACH actual TTS
        # attempt; this operation is never itself permission to make a call.
        return {"reservation": ledger.reserve(payload["provider"], payload["model"],
                    payload["maximumMicros"], payload.get("category", "narration"), payload.get("bounds"))}
    if operation == "settle":
        ledger.settle(payload["reservation"], payload.get("actualMicros"), payload.get("outcome", "unknown"))
        return ledger.summary()
    if operation == "prepare":
        body = base64.b64decode(payload.get("bodyBase64", ""), validate=True)
        body, quote = quote_request(payload["url"], payload.get("method", "POST"), body, payload.get("contentType", ""))
        if quote is None:
            return {"bodyBase64": base64.b64encode(body).decode(), "reservation": None}
        reservation = ledger.reserve("meta", quote["model"], quote["maximumMicros"],
                                     payload.get("category", "test"), quote["bounds"])
        return {"bodyBase64": base64.b64encode(body).decode(), "reservation": reservation, "quote": quote}
    if operation == "finish":
        actual, outcome = actual_cost(payload["quote"], integer(payload["status"], "status"),
                                      base64.b64decode(payload.get("bodyBase64", ""), validate=True))
        ledger.settle(payload["reservation"], actual, outcome)
        return ledger.summary()
    raise BudgetError("Unknown budget operation")


if __name__ == "__main__":
    try:
        print(json.dumps({"ok": True, "result": rpc(json.load(sys.stdin))}, allow_nan=False))
    except Exception as error:
        # Exceptions never include request bodies or provider responses.
        message = str(error) if isinstance(error, BudgetError) else "Invalid budget request or inaccessible ledger"
        print(json.dumps({"ok": False, "error": message}))
        sys.exit(1)
