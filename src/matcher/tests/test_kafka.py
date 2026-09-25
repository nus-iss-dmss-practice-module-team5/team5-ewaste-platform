import importlib.util
import os
import threading
import time
import unittest
from concurrent.futures import Future
from unittest.mock import Mock, patch

from matcher.contract import canonical, loads
from matcher.worker import Delivery, Processor, Record
from helpers import event
from test_facade import FixtureServer
from test_worker import FacadeDouble, PublisherDouble

HAS_CLIENT = importlib.util.find_spec("confluent_kafka") is not None


@unittest.skipUnless(HAS_CLIENT, "Kafka client is installed in the pinned Docker test image")
class OffsetTests(unittest.TestCase):
    def make_runner(self):
        from matcher.kafka import KafkaRunner
        with patch("matcher.kafka.Consumer") as consumer:
            runner = KafkaRunner({}, topic="ewaste.batch.events", group_id="unit", offset_reset="earliest",
                                  max_poll_ms=300000, session_timeout_ms=6000, workers=1,
                                  processor=Mock(retry_max=0), observer=Mock())
            return runner, consumer.return_value

    def test_commit_failure_retries_exact_offset_without_reprocessing(self):
        from confluent_kafka import KafkaException, TopicPartition
        from matcher.kafka import Job
        runner, consumer = self.make_runner()
        try:
            key = ("ewaste.batch.events", 0)
            runner.owned = {key}; runner.generation = 1
            delivery = Delivery(Record(*key, 5, b"key", b"{}"), "2026-09-19T00:00:00.000000Z", stage="DONE")
            runner.jobs[key] = Job(delivery, 1)
            consumer.commit.side_effect = [KafkaException(), [TopicPartition(*key, 6)]]
            runner._advance()
            self.assertIn(key, runner.jobs)
            runner._advance()
            self.assertNotIn(key, runner.jobs)
            self.assertEqual([c.kwargs["offsets"][0].offset for c in consumer.commit.call_args_list], [6, 6])
            runner.processor.step.assert_not_called()
        finally: runner.executor.shutdown()

    def test_revoked_inflight_completion_cannot_commit(self):
        from confluent_kafka import TopicPartition
        from matcher.kafka import Job
        runner, consumer = self.make_runner()
        try:
            key = ("ewaste.batch.events", 0); runner.owned = {key}; runner.generation = 1
            delivery = Delivery(Record(*key, 5, b"key", b"{}"), "2026-09-19T00:00:00.000000Z")
            future = Future(); runner.jobs[key] = Job(delivery, 1, future=future)
            future.set_running_or_notify_cancel()
            runner._revoke(consumer, [TopicPartition(*key)])
            delivery.stage = "DONE"; future.set_result(0)
            runner._advance()
            consumer.commit.assert_not_called()
        finally: runner.executor.shutdown()

    def test_revoke_cancels_queued_work(self):
        from confluent_kafka import TopicPartition
        from matcher.kafka import Job
        runner, consumer = self.make_runner()
        try:
            key = ("ewaste.batch.events", 0); runner.owned = {key}; runner.generation = 1
            delivery = Delivery(Record(*key, 5, b"key", b"{}"), "2026-09-19T00:00:00.000000Z")
            future = Future(); runner.jobs[key] = Job(delivery, 1, future=future)
            runner._revoke(consumer, [TopicPartition(*key)])
            self.assertTrue(future.cancelled())
            consumer.commit.assert_not_called()
        finally: runner.executor.shutdown()

    def test_lower_unresolved_offset_blocks_buffered_record(self):
        from matcher.kafka import Job
        runner, consumer = self.make_runner()
        try:
            key = ("ewaste.batch.events", 0); runner.owned = {key}; runner.generation = 1
            delivery = Delivery(Record(*key, 5, b"key", b"{}"), "2026-09-19T00:00:00.000000Z")
            runner.jobs[key] = Job(delivery, 1, due=time.monotonic() + 100,
                                    buffered=[Record(*key, 6, b"key", b"{}")])
            runner._advance()
            consumer.commit.assert_not_called()
            runner.processor.step.assert_not_called()
        finally: runner.executor.shutdown()


@unittest.skipUnless(os.environ.get("MATCHER_TEST_BROKER") and HAS_CLIENT, "requires isolated Kafka test broker")
class BrokerTests(unittest.TestCase):
    def test_real_kafka_outage_replay_dlq_and_consumer_restart(self):
        from confluent_kafka import Consumer, Producer, TopicPartition
        from confluent_kafka.admin import AdminClient, NewTopic
        from matcher.kafka import KafkaRunner, QuarantinePublisher
        common = {"bootstrap.servers": os.environ["MATCHER_TEST_BROKER"], "security.protocol": "PLAINTEXT"}
        # Protocol-double fixtures must not enter the real Go persistence stream.
        topic, dlq, group = "matcher.protocol-test.events", "matcher.protocol-test.dlq", "matcher-fixture-v1"
        admin = AdminClient(common)
        for pending in admin.create_topics([NewTopic(topic, 2, 1, config={"cleanup.policy": "delete"}),
                                            NewTopic(dlq, 1, 1, config={"cleanup.policy": "delete"})]).values():
            pending.result(timeout=20)
        facade = FacadeDouble(); facade.fail_result_once = True
        server = FixtureServer(facade); server.status = 503
        observations, stops, threads, failures = [], [], [], []
        inspect = Consumer({**common, "group.id": group, "enable.auto.commit": False, "enable.auto.offset.store": False})
        reader = Consumer({**common, "group.id": "dlq-fixture-reader", "enable.auto.commit": False,
                           "auto.offset.reset": "earliest"})
        def observe(name, delivery=None, **fields):
            observations.append((name, delivery.record.offset if delivery else None, fields))

        def start():
            processor = Processor(server.client(), QuarantinePublisher(common, dlq, 5), max_bytes=1_000_000,
                                   retry_base=0.1, retry_max=0.2, max_refreshes=3, observe=observe)
            runner = KafkaRunner(common, topic=topic, group_id=group, offset_reset="earliest", max_poll_ms=300000,
                                 session_timeout_ms=6000, workers=2, processor=processor, observer=observe)
            stop = threading.Event()
            def run():
                try: runner.run(stop)
                except Exception as exc: failures.append(type(exc).__name__)
            thread = threading.Thread(target=run, daemon=True)
            thread.start(); stops.append(stop); threads.append(thread)

        def until(predicate, seconds=25):
            deadline = time.monotonic() + seconds
            while time.monotonic() < deadline:
                self.assertFalse(failures, failures)
                if predicate(): return
                time.sleep(0.05)
            self.fail("Kafka fixture timed out: " + str(observations))

        producer = Producer({**common, "enable.idempotence": True, "acks": "all"})
        accepted = []
        def publish(value):
            producer.produce(topic, partition=0, key=event()["batch_id"].encode(), value=value,
                             on_delivery=lambda err, msg: accepted.append(err))
            self.assertEqual(producer.flush(10), 0)
            self.assertIsNone(accepted[-1])
        try:
            publish(canonical(event())); publish(canonical(event()))
            publish(b'{"private_note":"must-not-leak",')
            publish(b'{"event_type":"UnrelatedFutureType"}')
            start()
            until(lambda: any(x[0] == "delivery_paused" for x in observations))
            self.assertLess(inspect.committed([TopicPartition(topic, 0)], timeout=5)[0].offset, 0)
            server.status = 0
            until(lambda: any(x[:2] == ("offset_committed", 3) for x in observations))
            self.assertEqual(inspect.committed([TopicPartition(topic, 0)], timeout=5)[0].offset, 4)
            self.assertEqual([name for name, _ in facade.calls].count("result"), 1)
            self.assertIn("get", [name for name, _ in facade.calls])
            reader.assign([TopicPartition(dlq, 0, 0)])
            message = reader.poll(10)
            self.assertIsNotNone(message); self.assertIsNone(message.error())
            payload = loads(message.value())
            self.assertEqual(payload["source_offset"], "2")
            self.assertEqual(message.key(), payload["quarantine_id"].encode())
            self.assertNotIn(b"must-not-leak", message.value())
            stops[-1].set(); threads[-1].join(10); self.assertFalse(threads[-1].is_alive())
            publish(canonical(event()))
            start()
            until(lambda: any(x[:2] == ("offset_committed", 4) for x in observations))
            self.assertEqual(inspect.committed([TopicPartition(topic, 0)], timeout=5)[0].offset, 5)
            self.assertEqual([name for name, _ in facade.calls].count("result"), 1)
            print("KAFKA_EVIDENCE " + canonical({"broker": "apache/kafka:4.1.0", "records": 5,
                  "committed_next_offset": 5, "result_posts": 1, "dlq_records_verified": 1,
                  "api_boundary": "HTTP protocol test double; no SQL persistence claim"}).decode())
        finally:
            for stop in stops: stop.set()
            for thread in threads: thread.join(10)
            inspect.close(); reader.close(); server.close()
