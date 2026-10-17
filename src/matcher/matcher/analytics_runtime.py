"""Independent processing offsets, shared transport conventions and container probes."""
import os
from concurrent.futures import FIRST_COMPLETED, ThreadPoolExecutor, wait

from .analytics_worker import AnalyticsFacade, AnalyticsProcessor
from .contract import require
from .health import Health
from .kafka import KafkaRunner


class CombinedHealth(Health):
    def __init__(self, members, observer):
        super().__init__(observer)
        self.members = members

    def state(self, ready=False):
        return all(member.state(ready=ready) for member in self.members)


def analytics_runner(common, topic, matching_group, observe, positive, local):
    # Older matching-only installations remain supported. CD explicitly enables processing.
    enabled = os.environ.get("ANALYTICS_ENABLED", "true" if os.environ.get("ANALYTICS_SERVICE_TOKEN") else "false")
    require(enabled in ("true", "false"), "INVALID_ANALYTICS_CONFIGURATION")
    if enabled == "false":
        return None
    require(len(os.environ.get("ANALYTICS_SERVICE_TOKEN", "")) >= 32, "INVALID_ANALYTICS_CONFIGURATION")
    group = os.environ.get("ANALYTICS_GROUP_ID", "analytics-processing-v1")
    require(bool(group) and group != matching_group, "INVALID_ANALYTICS_CONFIGURATION")
    health = Health(observer=observe)
    def observer(name, delivery=None, **fields):
        fields.setdefault("consumer_group", group)
        observe(name, delivery, **fields)
        health.observe(name, delivery, **fields)
    facade = AnalyticsFacade(os.environ.get("ANALYTICS_FACADE_URL", ""), None,
                             positive("MATCHER_HTTP_TIMEOUT_SECONDS"), positive("MATCHER_MAX_RESPONSE_BYTES"),
                             local=local, token_provider=lambda: os.environ["ANALYTICS_SERVICE_TOKEN"])
    processor = AnalyticsProcessor(facade, max_bytes=positive("MATCHER_MAX_RECORD_BYTES"),
                                   retry_base=positive("MATCHER_RETRY_BASE_SECONDS"),
                                   retry_max=positive("MATCHER_RETRY_MAX_SECONDS"), observe=observer)
    require(processor.retry_base <= processor.retry_max)
    runner = KafkaRunner(common, topic=topic, group_id=group, offset_reset="earliest",
                         max_poll_ms=positive("MATCHER_MAX_POLL_MS"),
                         session_timeout_ms=positive("MATCHER_SESSION_TIMEOUT_MS"),
                         workers=positive("MATCHER_WORKERS"), processor=processor, observer=observer, health=health)
    return runner, health


def run_workers(runners, stop):
    # A dead runner must fail the container; it cannot leave the other loop looking healthy.
    with ThreadPoolExecutor(max_workers=len(runners), thread_name_prefix="workflow-consumer") as pool:
        futures = [pool.submit(runner.run, stop) for runner in runners]
        try:
            wait(futures, return_when=FIRST_COMPLETED)
            unexpected_exit = not stop.is_set()
        finally:
            stop.set()
        for future in futures:
            future.result()
        if unexpected_exit:
            raise RuntimeError("consumer stopped unexpectedly")
