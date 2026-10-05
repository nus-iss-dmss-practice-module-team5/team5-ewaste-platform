import unittest
import base64
import json
from unittest.mock import patch
from analytics.contract import ContractError
from analytics.config import environment
from analytics.__main__ import positive
from analytics.runtime import kafka_config, token_provider
from analytics.health import Health


class RuntimeTests(unittest.TestCase):
    def test_new_settings_take_precedence_without_mutating_environment(self):
        source = {"MATCHER_WORKERS": "4", "ANALYTICS_WORKERS": "2", "MATCHER_GROUP_ID": "matching-worker-v1"}
        resolved = environment(source)
        self.assertEqual(resolved["ANALYTICS_WORKERS"], "2")
        self.assertEqual(resolved["ANALYTICS_GROUP_ID"], "matching-worker-v1")
        self.assertNotIn("ANALYTICS_GROUP_ID", source)

    def test_empty_new_value_does_not_silently_restore_legacy_setting(self):
        with patch.dict("os.environ", {"ANALYTICS_WORKERS": "", "MATCHER_WORKERS": "1"}, clear=True):
            with self.assertRaises(ContractError):
                positive("ANALYTICS_WORKERS")

    def test_legacy_local_switch_cannot_override_new_transport_policy(self):
        with self.assertRaises(ContractError):
            kafka_config({"KAFKA_BOOTSTRAP_SERVERS": "kafka:9092", "ANALYTICS_LOCAL_TEST": "0", "MATCHER_LOCAL_TEST": "1"})

    def test_legacy_and_new_keys_issue_identical_tokens(self):
        new = {"ANALYTICS_SIGNING_SECRET": "x" * 32, "ANALYTICS_TOKEN_ISSUER": "test", "ANALYTICS_TOKEN_AUDIENCE": "api"}
        legacy = {name.replace("ANALYTICS_", "MATCHER_", 1): value for name, value in new.items()}
        with patch("time.time", return_value=1000):
            self.assertEqual(token_provider(new)(), token_provider(legacy)())
            mixed = {**legacy, **new, "MATCHER_SIGNING_SECRET": "y" * 32}
            self.assertEqual(token_provider(mixed)(), token_provider(new)())

    def test_azure_configuration(self):
        config = kafka_config({"KAFKA_BOOTSTRAP_SERVERS": "example.servicebus.windows.net:9093",
                               "KAFKA_CONNECTION_STRING": "test-secret"})
        self.assertEqual(config["security.protocol"], "SASL_SSL")
        self.assertEqual(config["sasl.username"], "$ConnectionString")
        self.assertEqual(config["request.timeout.ms"], 60000)
        self.assertEqual(config["metadata.max.age.ms"], 180000)

    def test_missing_azure_credentials_fail_closed(self):
        for local in ("0", "1"):
            with self.assertRaises(ContractError):
                kafka_config({"KAFKA_BOOTSTRAP_SERVERS": "example.servicebus.windows.net:9093",
                              "ANALYTICS_LOCAL_TEST": local})

    def test_plaintext_requires_local_switch(self):
        with self.assertRaises(ContractError):
            kafka_config({"KAFKA_BOOTSTRAP_SERVERS": "kafka:9092"})
        self.assertEqual(kafka_config({"KAFKA_BOOTSTRAP_SERVERS": "kafka:9092", "ANALYTICS_LOCAL_TEST": "1"})["security.protocol"], "PLAINTEXT")

    def test_short_lived_tokens_refresh_without_operator_scope(self):
        env = {"ANALYTICS_SIGNING_SECRET": "x" * 32, "ANALYTICS_TOKEN_ISSUER": "test", "ANALYTICS_TOKEN_AUDIENCE": "api"}
        provider = token_provider(env)
        with patch("time.time", return_value=1000):
            first = provider()
        with patch("time.time", return_value=1300):
            second = provider()
        decode = lambda token: json.loads(base64.urlsafe_b64decode(token.split(".")[1] + "=="))
        self.assertEqual(decode(first)["exp"], 1300)
        self.assertEqual(decode(second)["exp"], 1600)
        self.assertNotIn("matching.rerun", decode(second)["scope"])

    def test_readiness_requires_polling_and_live_broker_statistics(self):
        health = Health()
        self.assertFalse(health.state(ready=True))
        health.polled()
        self.assertTrue(health.state())
        self.assertFalse(health.state(ready=True))
        health.stats(json.dumps({"brokers": {"one": {"state": "UP"}}, "cgrp": {"state": "up"}}))
        self.assertTrue(health.state(ready=True))
        health.blocked.add(("topic", 0))
        self.assertFalse(health.state(ready=True))
        health.revoked([("topic", 0)])
        self.assertTrue(health.state(ready=True))
        health.stats(json.dumps({"brokers": {"one": {"state": "DOWN"}}, "cgrp": {"state": "up"}}))
        self.assertFalse(health.state(ready=True))
