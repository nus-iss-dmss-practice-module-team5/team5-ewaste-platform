import io
import os
import signal
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from analytics.__main__ import main, positive, required
from analytics.contract import ContractError, canonical, loads
from helpers import fixture


class MainTests(unittest.TestCase):
    def environment(self):
        return {
            "ANALYTICS_LOCAL_TEST": "1", "KAFKA_BOOTSTRAP_SERVERS": "kafka:9092",
            "ANALYTICS_TOPIC": "ewaste.batch.events", "ANALYTICS_DLQ_TOPIC": "ewaste.matching.dlq",
            "ANALYTICS_GROUP_ID": "matching-worker-v1", "ANALYTICS_FACADE_URL": "http://api:8080",
            "ANALYTICS_TOKEN_FILE": "/test-fixtures/token", "ANALYTICS_HTTP_TIMEOUT_SECONDS": "5",
            "ANALYTICS_MAX_RESPONSE_BYTES": "100000", "ANALYTICS_DELIVERY_TIMEOUT_SECONDS": "10",
            "ANALYTICS_MAX_RECORD_BYTES": "100000", "ANALYTICS_RETRY_BASE_SECONDS": "1",
            "ANALYTICS_RETRY_MAX_SECONDS": "30", "ANALYTICS_MAX_REFRESHES": "3",
            "ANALYTICS_OFFSET_RESET": "earliest", "ANALYTICS_MAX_POLL_MS": "300000",
            "ANALYTICS_SESSION_TIMEOUT_MS": "6000", "ANALYTICS_WORKERS": "2",
        }

    def test_evaluate_command_writes_the_canonical_golden_result(self):
        golden = fixture()
        output = io.BytesIO()
        with patch("sys.argv", ["analytics", "evaluate"]), \
                patch("sys.stdin", SimpleNamespace(buffer=io.BytesIO(canonical(golden["input"])))), \
                patch("sys.stdout", SimpleNamespace(buffer=output)):
            self.assertEqual(main(), 0)
        self.assertEqual(loads(output.getvalue()), golden["expected_output"])
        self.assertEqual(output.getvalue(), canonical(golden["expected_output"]) + b"\n")

    def test_evaluate_command_reports_invalid_input_without_partial_output(self):
        output, errors = io.BytesIO(), io.StringIO()
        with patch("sys.argv", ["analytics", "evaluate"]), \
                patch("sys.stdin", SimpleNamespace(buffer=io.BytesIO(b'{"private":"invalid",'))), \
                patch("sys.stdout", SimpleNamespace(buffer=output)), patch("sys.stderr", errors):
            self.assertEqual(main(), 2)
        self.assertEqual(output.getvalue(), b"")
        self.assertEqual(errors.getvalue(), "INVALID_CONTRACT\n")

    def test_invalid_command_and_missing_or_nonpositive_settings_fail_closed(self):
        for args in ([], ["unknown"], ["run", "extra"]):
            with self.subTest(args=args), patch("sys.argv", ["analytics", *args]), self.assertRaises(ContractError):
                main()
        for value in (None, "", "0", "-1"):
            env = {} if value is None else {"ANALYTICS_WORKERS": value}
            with self.subTest(value=value), patch.dict(os.environ, env, clear=True), self.assertRaises(ContractError):
                positive("ANALYTICS_WORKERS")
        with patch.dict(os.environ, {"ANALYTICS_WORKERS": "2"}, clear=True):
            self.assertEqual(required("ANALYTICS_WORKERS"), "2")
            self.assertEqual(positive("ANALYTICS_WORKERS"), 2)

    def test_run_wires_local_and_azure_settings_and_signal_shutdown(self):
        for azure, legacy in ((False, False), (True, False), (False, True), (True, True)):
            with self.subTest(azure=azure, legacy=legacy):
                env = self.environment()
                if azure:
                    env.pop("ANALYTICS_LOCAL_TEST")
                    env.pop("ANALYTICS_TOKEN_FILE")
                    env.update(KAFKA_BOOTSTRAP_SERVERS="test.servicebus.windows.net:9093",
                               KAFKA_CONNECTION_STRING="test-only-connection",
                               ANALYTICS_FACADE_URL="https://api.example.test",
                               ANALYTICS_SIGNING_SECRET="x" * 32, ANALYTICS_TOKEN_ISSUER="test",
                               ANALYTICS_TOKEN_AUDIENCE="matching-api", ANALYTICS_HEALTH_PORT="8000")
                    for source, fallback in (("ANALYTICS_TOPIC", "KAFKA_TOPIC_BATCH_EVENTS"),
                                             ("ANALYTICS_DLQ_TOPIC", "KAFKA_TOPIC_DLQ"),
                                             ("ANALYTICS_GROUP_ID", "KAFKA_CONSUMER_GROUP")):
                        env[fallback] = env.pop(source)
                if legacy:
                    env = {key.replace("ANALYTICS_", "MATCHER_", 1): value for key, value in env.items()}
                with patch.dict(os.environ, env, clear=True), patch("sys.argv", ["analytics", "run"]), \
                        patch("analytics.facade.FacadeClient") as facade, \
                        patch("analytics.kafka.QuarantinePublisher") as publisher, \
                        patch("analytics.kafka.KafkaRunner") as runner, \
                        patch("analytics.kafka.observe") as observe, \
                        patch("analytics.health.Health") as health, patch("signal.signal") as signals:
                    def stop_on_signal(stop):
                        self.assertFalse(stop.is_set())
                        for call in signals.call_args_list:
                            call.args[1]()
                        self.assertTrue(stop.is_set())
                        runner.call_args.kwargs["observer"]("consumer_error", code="test")
                    runner.return_value.run.side_effect = stop_on_signal
                    self.assertEqual(main(), 0)
                    config = runner.call_args.args[0]
                    self.assertEqual(config["security.protocol"], "SASL_SSL" if azure else "PLAINTEXT")
                    options = runner.call_args.kwargs
                    self.assertEqual((options["topic"], options["group_id"], options["workers"]),
                                     ("ewaste.batch.events", "matching-worker-v1", 2))
                    processor = options["processor"]
                    self.assertIs(processor.facade, facade.return_value)
                    self.assertIs(processor.publisher, publisher.return_value)
                    self.assertEqual((processor.retry_base, processor.retry_max, processor.max_refreshes), (1, 30, 3))
                    self.assertEqual(facade.call_args.kwargs["local"], not azure)
                    provider = facade.call_args.kwargs["token_provider"]
                    if azure:
                        self.assertIsNone(facade.call_args.args[1])
                        self.assertEqual(len(provider().split(".")), 3)
                        health.return_value.serve.assert_called_once_with(8000)
                        health.return_value.serve.return_value.shutdown.assert_called_once_with()
                        health.return_value.serve.return_value.server_close.assert_called_once_with()
                    else:
                        self.assertIsNone(provider)
                        self.assertEqual(facade.call_args.args[1], "/test-fixtures/token")
                        health.return_value.serve.assert_not_called()
                    self.assertEqual([c.args[0] for c in signals.call_args_list], [signal.SIGINT, signal.SIGTERM])
                    observe.assert_called_once_with("consumer_error", None, code="test")
                    health.return_value.observe.assert_called_once_with("consumer_error", None, code="test")

    def test_run_closes_health_server_when_runner_fails(self):
        env = {**self.environment(), "ANALYTICS_HEALTH_PORT": "8000"}
        with patch.dict(os.environ, env, clear=True), patch("sys.argv", ["analytics", "run"]), \
                patch("analytics.facade.FacadeClient"), patch("analytics.kafka.QuarantinePublisher"), \
                patch("analytics.kafka.KafkaRunner") as runner, patch("analytics.health.Health") as health, \
                patch("signal.signal"):
            runner.return_value.run.side_effect = RuntimeError("test failure")
            with self.assertRaisesRegex(RuntimeError, "test failure"):
                main()
            health.return_value.serve.return_value.shutdown.assert_called_once_with()
            health.return_value.serve.return_value.server_close.assert_called_once_with()

    def test_invalid_topics_or_retry_bounds_do_not_start_consumer(self):
        for update in ({"ANALYTICS_DLQ_TOPIC": "ewaste.batch.events"}, {"ANALYTICS_RETRY_BASE_SECONDS": "31"}):
            with self.subTest(update=update), patch.dict(os.environ, {**self.environment(), **update}, clear=True), \
                    patch("sys.argv", ["analytics", "run"]), patch("analytics.facade.FacadeClient"), \
                    patch("analytics.kafka.QuarantinePublisher"), patch("analytics.kafka.KafkaRunner") as runner:
                with self.assertRaises(ContractError):
                    main()
                runner.assert_not_called()
