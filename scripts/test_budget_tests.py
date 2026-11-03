#!/usr/bin/env python3
"""Offline adversarial checks. Never calls a provider or consumes credit."""
import base64
import concurrent.futures
import importlib.util
import io
import json
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
import wave

sys.path.insert(0, str(Path(__file__).parent))
import test_budget as budget


def competing_reservation(path):
    try:
        return budget.Ledger(path).reserve("meta", "muse-image-1.0", 100_000)
    except budget.BudgetError:
        return None


class BudgetTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.path = str(Path(self.temp.name) / "ledger.json")
        self.ledger = budget.Ledger(self.path)

    def tearDown(self):
        self.temp.cleanup()

    def quote(self, body, path="chat/completions"):
        return budget.quote_request("https://api.meta.ai/v1/" + path, "POST", json.dumps(body).encode(), "application/json")

    def test_process_race_never_exceeds_planned_cap(self):
        context = multiprocessing.get_context("spawn")
        with concurrent.futures.ProcessPoolExecutor(max_workers=8, mp_context=context) as executor:
            fits = budget.PLANNED // 100_000
            results = list(executor.map(competing_reservation, [self.path] * (fits + 19)))
        self.assertEqual(sum(value is not None for value in results), fits)
        self.assertEqual(self.ledger.summary()["liabilityMicros"], fits * 100_000)
        self.assertEqual(len({r for r in results if r}), fits)

    def test_unknown_and_restart_cannot_free_money(self):
        held = budget.PLANNED - 500_000
        identifier = self.ledger.reserve("meta", "muse-spark-1.3", held)
        self.ledger.settle(identifier, None, "network_error")
        reopened = budget.Ledger(self.path)
        self.assertEqual(reopened.summary()["liabilityMicros"], held)
        with self.assertRaises(budget.BudgetError):
            reopened.reserve("elevenlabs", "stock-voice", 500_001)
        with self.assertRaises(budget.BudgetError):
            reopened.settle(identifier, 0, "complete")

    def test_settlement_and_double_settlement(self):
        identifier = self.ledger.reserve("meta", "muse-spark-1.3", 1_000_000)
        self.ledger.settle(identifier, 42_000, "complete")
        with self.assertRaises(budget.BudgetError):
            self.ledger.settle(identifier, 0, "complete")
        self.assertEqual(self.ledger.summary()["liabilityMicros"], 42_000)

    def test_overrun_freezes_future_attempts(self):
        identifier = self.ledger.reserve("meta", "muse-image-1.0", 10_000)
        with self.assertRaises(budget.BudgetError):
            self.ledger.settle(identifier, 20_000, "complete")
        self.assertTrue(self.ledger.summary()["frozen"])
        with self.assertRaises(budget.BudgetError):
            self.ledger.reserve("meta", "sam-3.1", 2500)

    def test_every_retry_is_a_distinct_reserved_attempt(self):
        identifiers = []
        for outcome in ("network_error", "http_error", "complete"):
            identifier = self.ledger.reserve("meta", "sam-3.1", 2500)
            identifiers.append(identifier)
            self.ledger.settle(identifier, 2500 if outcome == "complete" else None, outcome)
        self.assertEqual(len(set(identifiers)), 3)
        self.assertEqual(self.ledger.summary()["liabilityMicros"], 7500)

    def test_corrupt_limits_and_symlinks_fail_closed(self):
        Path(self.path).write_text('{"schema":1,"plannedMicros":99999999}')
        with self.assertRaises(budget.BudgetError):
            self.ledger.reserve("meta", "sam-3.1", 2500)
        Path(self.path).unlink()
        Path(self.path).symlink_to(Path(self.temp.name) / "other")
        with self.assertRaises(budget.BudgetError):
            budget.Ledger(self.path)

    def test_bounds_and_safe_rpc_redaction(self):
        body = {"model": "muse-spark-1.3", "messages": [{"role": "user", "content": "secret prompt"}]}
        bounded, quote = self.quote(body)
        self.assertEqual(json.loads(bounded)["max_completion_tokens"], 8192)
        self.assertLess(quote["maximumMicros"], 100_000)
        payload = {"ledger": self.path, "operation": "prepare", "url": "https://api.meta.ai/v1/chat/completions",
                   "method": "POST", "contentType": "application/json", "bodyBase64": base64.b64encode(json.dumps(body).encode()).decode()}
        answer = budget.rpc(payload)
        self.assertIsNotNone(answer["reservation"])
        ledger = Path(self.path).read_text()
        self.assertNotIn("secret prompt", ledger)
        self.assertNotIn("messages", ledger)
        self.assertEqual(os.stat(self.path).st_mode & 0o777, 0o600)

    def test_multimodal_reserves_documented_context_not_guessed_image_tokens(self):
        _, quote = self.quote({"model": "muse-spark-1.3", "messages": [{"role": "user", "content": [
            {"type": "image_url", "image_url": {"url": "data:image/png;base64,AA=="}}]}]})
        self.assertEqual(quote["bounds"]["inputTokens"], 1_048_576)
        self.assertEqual(quote["maximumMicros"], 1_345_536)

    def test_unknown_hosts_models_tools_videos_and_streams_refused(self):
        for body, path in [({"model": "unknown"}, "chat/completions"),
                           ({"model": "muse-spark-1.3", "tools": [{"type": "web_search"}]}, "chat/completions"),
                           ({"model": "muse-spark-1.3", "stream": True}, "chat/completions"),
                           ({"model": "sam-3.1", "input": [{"type": "input_video"}]}, "responses"),
                           ({"model": "muse-image-1.0", "n": 100}, "images/edits")]:
            with self.assertRaises(budget.BudgetError):
                self.quote(body, path)
        for url in ("https://api.meta.ai.evil.invalid/v1/chat/completions", "http://api.meta.ai/v1/chat/completions",
                    "https://user:pass@api.meta.ai/v1/chat/completions", "https://api.meta.ai/v1/chat/completions?key=secret"):
            with self.assertRaises(budget.BudgetError):
                budget.quote_request(url, "POST", b"{}", "application/json")

    def test_missing_usage_http_failure_and_cancellation_keep_bound(self):
        _, quote = self.quote({"model": "muse-spark-1.3", "messages": []})
        for status, body in ((200, b"{}"), (429, b"{}"), (500, b"{}"), (200, b"not json")):
            actual, _ = budget.actual_cost(quote, status, body)
            self.assertIsNone(actual)
        identifier = self.ledger.reserve("meta", quote["model"], quote["maximumMicros"])
        self.ledger.settle(identifier, None, "cancelled")
        self.assertEqual(self.ledger.summary()["liabilityMicros"], quote["maximumMicros"])

    def test_known_usage_is_rounded_up_and_cached_discount_is_not_assumed(self):
        _, quote = self.quote({"model": "muse-spark-1.3", "messages": []})
        actual, outcome = budget.actual_cost(quote, 200, b'{"usage":{"prompt_tokens":3,"completion_tokens":1}}')
        self.assertEqual((actual, outcome), (8, "complete"))

    def test_transcription_partial_seconds_never_release_an_underestimate(self):
        quote = {"model": "muse-voice-transcribe-1.0", "maximumMicros": 30_000, "bounds": {"audioSeconds": 600}}
        self.assertEqual(budget.actual_cost(quote, 200, b'{"audioDurationMs":999}'), (50, "complete"))
        self.assertEqual(budget.actual_cost(quote, 200, b'{"audioDurationMs":1500}'), (100, "complete"))
        self.assertEqual(budget.actual_cost(quote, 200, b'{}'), (None, "missing_usage"))
        self.assertEqual(999 // 1000 * 50, 0)  # Published provider rounding, deliberately not used by the task guard.
        self.assertEqual(1500 // 1000 * 50, 50)

    def test_rpc_invalid_payload_never_echoes_secret(self):
        result = subprocess.run([sys.executable, str(Path(budget.__file__))], input=b'{"secret":"sk-do-not-print"}', capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(b"sk-do-not-print", result.stdout + result.stderr)

    def test_offline_mode_and_private_bound_fields(self):
        with self.assertRaises(budget.BudgetError):
            budget.rpc({"ledger": self.path, "operation": "prepare", "denyNetwork": True,
                        "url": "https://api.meta.ai/v1/chat/completions", "method": "POST",
                        "contentType": "application/json", "bodyBase64": "e30="})
        self.assertFalse(Path(self.path).exists())
        with self.assertRaises(budget.BudgetError):
            self.ledger.reserve("elevenlabs", "stock-voice", 500_000, bounds={"voiceText": "private text"})
        identifier = self.ledger.reserve("elevenlabs", "stock-voice", 500_000,
                                         bounds={"characters": 1000, "rateMicrosPer1000": 200_000, "priceDate": "2026-11-02"})
        self.ledger.settle(identifier, 200_000, "complete")
        self.assertEqual(self.ledger.summary()["liabilityMicros"], 200_000)


if __name__ == "__main__":
    unittest.main(verbosity=2)
