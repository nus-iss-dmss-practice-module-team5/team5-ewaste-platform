import json
import logging
import os
import threading
import time
import uuid
from collections import deque
from contextlib import asynccontextmanager
from typing import Any, Dict, Optional

from fastapi import FastAPI, HTTPException
from kafka import KafkaConsumer, KafkaProducer
from pydantic import BaseModel

# Configure Logging
logging.basicConfig(
    level=os.getenv("LOG_LEVEL", "INFO"),
    format="%(asctime)s [%(levelname)s] [%(name)s] %(message)s",
)
logger = logging.getLogger("matching-worker")

# Environment & Kafka Configuration
KAFKA_BOOTSTRAP_SERVERS = os.getenv("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
KAFKA_CONNECTION_STRING = os.getenv("KAFKA_CONNECTION_STRING", "")
KAFKA_TOPIC_BATCH_EVENTS = os.getenv("KAFKA_TOPIC_BATCH_EVENTS", "ewaste.batch.events")
KAFKA_TOPIC_DLQ = os.getenv("KAFKA_TOPIC_DLQ", "ewaste.batch.events.matching.dlq.v1")
CONSUMER_GROUP = os.getenv("KAFKA_CONSUMER_GROUP", "matching-worker")

# In-memory circular buffer to inspect recently consumed events via API (last 50)
recent_received_events: deque = deque(maxlen=50)

# Global producer handle
producer: Optional[KafkaProducer] = None
consumer_thread: Optional[threading.Thread] = None
stop_consumer_event = threading.Event()


def get_kafka_producer_kwargs() -> dict:
    """Builds standard SASL_SSL authentication options for Azure Event Hubs."""
    kwargs: Dict[str, Any] = {
        "bootstrap_servers": [s.strip() for s in KAFKA_BOOTSTRAP_SERVERS.split(",")],
        "value_serializer": lambda v: json.dumps(v).encode("utf-8"),
        "key_serializer": lambda k: k.encode("utf-8") if k else None,
        "acks": "all",
        "retries": 3,
    }
    # If connection string is provided, authenticate via SASL_SSL for Azure Event Hubs
    if KAFKA_CONNECTION_STRING:
        kwargs.update(
            {
                "security_protocol": "SASL_SSL",
                "sasl_mechanism": "PLAIN",
                "sasl_plain_username": "$ConnectionString",
                "sasl_plain_password": KAFKA_CONNECTION_STRING,
                "ssl_check_hostname": True,
            }
        )
    return kwargs


def get_kafka_consumer_kwargs() -> dict:
    """Builds SASL_SSL options for consuming from Azure Event Hubs."""
    kwargs: Dict[str, Any] = {
        "bootstrap_servers": [s.strip() for s in KAFKA_BOOTSTRAP_SERVERS.split(",")],
        "group_id": CONSUMER_GROUP,
        "auto_offset_reset": "earliest",
        "enable_auto_commit": True,
        "value_deserializer": lambda m: json.loads(m.decode("utf-8")),
        "key_deserializer": lambda k: k.decode("utf-8") if k else None,
    }
    if KAFKA_CONNECTION_STRING:
        kwargs.update(
            {
                "security_protocol": "SASL_SSL",
                "sasl_mechanism": "PLAIN",
                "sasl_plain_username": "$ConnectionString",
                "sasl_plain_password": KAFKA_CONNECTION_STRING,
                "ssl_check_hostname": True,
            }
        )
    return kwargs


def kafka_consumer_loop():
    """Background consumer daemon that listens on ewaste.batch.events."""
    logger.info(f"Starting background Kafka consumer on topic: '{KAFKA_TOPIC_BATCH_EVENTS}'...")

    retries = 0
    while not stop_consumer_event.is_set():
        try:
            consumer = KafkaConsumer(KAFKA_TOPIC_BATCH_EVENTS, **get_kafka_consumer_kwargs())
            logger.info("Kafka consumer connected successfully to Azure Event Hubs.")

            for message in consumer:
                if stop_consumer_event.is_set():
                    break

                event_data = {
                    "topic": message.topic,
                    "partition": message.partition,
                    "offset": message.offset,
                    "key": message.key,
                    "value": message.value,
                    "consumed_at": time.time(),
                }
                recent_received_events.appendleft(event_data)
                logger.info(
                    f"Consuming Event: key={message.key} "
                    f"event_type={message.value.get('event_type')} "
                    f"offset={message.offset}"
                )

            consumer.close()
        except Exception as err:
            logger.warning(f"Kafka consumer connection retry in 5s due to: {err}")
            time.sleep(5)


@asynccontextmanager
async def lifespan(app: FastAPI):
    # --- Startup ---
    global producer, consumer_thread
    logger.info("Initializing Kafka Producer...")
    try:
        producer = KafkaProducer(**get_kafka_producer_kwargs())
        logger.info("Kafka Producer initialized.")
    except Exception as e:
        logger.error(f"Failed to initialize Kafka Producer: {e}")

    # Launch background consumer thread
    consumer_thread = threading.Thread(target=kafka_consumer_loop, daemon=True)
    consumer_thread.start()

    yield

    # --- Shutdown ---
    logger.info("Stopping Kafka Consumer thread...")
    stop_consumer_event.set()
    if producer:
        producer.flush()
        producer.close()
    logger.info("Shutdown complete.")


app = FastAPI(
    title="Matching Worker & EventHub Test API",
    version="1.0.0",
    description="Simulates Go relay event publishing and Python matching event consumption.",
    lifespan=lifespan,
)


class PublishTestRequest(BaseModel):
    batch_id: Optional[str] = None
    event_type: str = "RequestSubmitted"
    category: str = "ICT_EQUIPMENT"
    quantity: int = 10
    zone: str = "NORTH"


@app.get("/healthz")
def health_check():
    """Liveness & Readiness probe for Azure Container Apps."""
    return {
        "status": "healthy",
        "bootstrap_servers": KAFKA_BOOTSTRAP_SERVERS,
        "consumer_active": consumer_thread.is_alive() if consumer_thread else False,
    }


@app.get("/api/v1/events")
def list_consumed_events():
    """Returns the recent events consumed by the worker from Event Hubs."""
    return {
        "count": len(recent_received_events),
        "events": list(recent_received_events),
    }


@app.post("/api/v1/publish-test")
def publish_test_event(req: PublishTestRequest):
    """Produces a dummy EWCSB-107 compliant event to ewaste.batch.events."""
    if not producer:
        raise HTTPException(status_code=503, detail="Kafka producer is not connected.")

    batch_id = req.batch_id or str(uuid.uuid4())
    event_id = str(uuid.uuid4())
    command_id = str(uuid.uuid4())

    envelope = {
        "event_id": event_id,
        "event_type": req.event_type,
        "schema_version": 1,
        "command_id": command_id,
        "batch_id": batch_id,
        "batch_version": 1,
        "claim_epoch": "1",
        "sequence_in_command": 1,
        "occurred_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "correlation_id": f"test-trace-{uuid.uuid4().hex[:8]}",
        "data": {
            "organization_id": "DON-001",
            "submitted_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "category": req.category,
            "quantity": req.quantity,
            "estimated_weight_kg": "50.00",
            "condition_rating": "REPAIRABLE",
            "is_data_bearing": True,
            "zone": req.zone,
            "collection_deadline": "2026-10-01T00:00:00Z",
        },
    }

    try:
        # Key must be UTF-8 string of batch_id as specified in Task EWCSB-107
        future = producer.send(
            topic=KAFKA_TOPIC_BATCH_EVENTS,
            key=batch_id,
            value=envelope,
        )
        record_metadata = future.get(timeout=10)
        return {
            "status": "published",
            "topic": record_metadata.topic,
            "partition": record_metadata.partition,
            "offset": record_metadata.offset,
            "batch_id": batch_id,
            "event_id": event_id,
        }
    except Exception as exc:
        logger.error(f"Failed to publish message: {exc}")
        raise HTTPException(status_code=500, detail=str(exc))
