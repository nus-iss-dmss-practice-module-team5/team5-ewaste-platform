import logging
import signal
import sys
import threading
from pathlib import Path

from .contract import ContractError, canonical, loads, require
from .config import environment
from .core import evaluate


def required(name):
    value = environment().get(name)
    require(bool(value))
    return value


def positive(name):
    value = int(required(name))
    require(value > 0)
    return value


def main():
    if sys.argv[1:] == ["evaluate"]:
        try:
            result = evaluate(loads(sys.stdin.buffer.read()))
            sys.stdout.buffer.write(canonical(result) + b"\n")
        except ContractError as exc:
            print(exc.code, file=sys.stderr)
            return 2
        return 0
    require(sys.argv[1:] == ["run"])
    from .facade import FacadeClient
    from .kafka import KafkaRunner, QuarantinePublisher, observe
    from .worker import Processor
    from .health import Health

    logging.basicConfig(level=logging.INFO, format="%(message)s")
    from .runtime import kafka_config, token_file, token_provider
    common = kafka_config()
    env = environment()
    local = env.get("ANALYTICS_LOCAL_TEST") == "1"
    require(common.get("security.protocol") in (("PLAINTEXT", "SSL", "SASL_SSL") if local else ("SSL", "SASL_SSL")))
    require(bool(common.get("bootstrap.servers")))
    topic = env.get("ANALYTICS_TOPIC") or required("KAFKA_TOPIC_BATCH_EVENTS")
    dlq = env.get("ANALYTICS_DLQ_TOPIC") or required("KAFKA_TOPIC_DLQ")
    require(topic != dlq)
    provider = token_provider()
    facade = FacadeClient(required("ANALYTICS_FACADE_URL"), None if provider else token_file(),
                          positive("ANALYTICS_HTTP_TIMEOUT_SECONDS"), positive("ANALYTICS_MAX_RESPONSE_BYTES"),
                          local=local, token_provider=provider)
    publisher = QuarantinePublisher(common, dlq, positive("ANALYTICS_DELIVERY_TIMEOUT_SECONDS"))
    health = Health()
    def observer(name, delivery=None, **fields):
        observe(name, delivery, **fields)
        health.observe(name, delivery, **fields)
    processor = Processor(facade, publisher, max_bytes=positive("ANALYTICS_MAX_RECORD_BYTES"),
                          retry_base=positive("ANALYTICS_RETRY_BASE_SECONDS"), retry_max=positive("ANALYTICS_RETRY_MAX_SECONDS"),
                          max_refreshes=positive("ANALYTICS_MAX_REFRESHES"), observe=observer)
    require(processor.retry_base <= processor.retry_max)
    runner = KafkaRunner(common, topic=topic, group_id=env.get("ANALYTICS_GROUP_ID") or required("KAFKA_CONSUMER_GROUP"),
                         offset_reset=required("ANALYTICS_OFFSET_RESET"), max_poll_ms=positive("ANALYTICS_MAX_POLL_MS"),
                         session_timeout_ms=positive("ANALYTICS_SESSION_TIMEOUT_MS"), workers=positive("ANALYTICS_WORKERS"),
                         processor=processor, observer=observer, health=health)
    stop = threading.Event()
    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, lambda *_: stop.set())
    server = health.serve(positive("ANALYTICS_HEALTH_PORT")) if env.get("ANALYTICS_HEALTH_PORT") else None
    try:
        runner.run(stop)
    finally:
        if server:
            server.shutdown()
            server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
