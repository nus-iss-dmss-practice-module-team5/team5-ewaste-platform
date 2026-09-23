package eventbus

import (
	"context"
	"encoding/json"
	"errors"
	"strconv"
	"strings"
	"time"

	"github.com/google/uuid"
	"github.com/segmentio/kafka-go"

	"workflow-api/internal/config"
	"workflow-api/internal/model"
)

var (
	ErrKafkaPublisherUnavailable = errors.New("kafka publisher is unavailable")
	ErrKafkaTopicMissing         = errors.New("kafka topic is missing")
	ErrKafkaPayloadMissing       = errors.New("kafka payload is missing")
)

// InvalidEventError identifies an immutable outbox record that cannot be
// safely published. These records are quarantined instead of retried.
type InvalidEventError struct {
	cause error
}

func (e *InvalidEventError) Error() string {
	return e.cause.Error()
}

func (e *InvalidEventError) Unwrap() error {
	return e.cause
}

func (e *InvalidEventError) Permanent() bool {
	return true
}

type KafkaPublisher struct {
	writer *kafka.Writer
}

func NewKafkaPublisher(cfg config.KafkaConfig) (*KafkaPublisher, error) {
	brokers := make([]string, 0, len(cfg.Brokers))

	for _, broker := range cfg.Brokers {
		broker = strings.TrimSpace(broker)
		if broker != "" {
			brokers = append(brokers, broker)
		}
	}

	if len(brokers) == 0 {
		return nil, errors.New("kafka brokers are not configured")
	}

	publishTimeout := cfg.PublishTimeout
	if publishTimeout <= 0 {
		publishTimeout = 10 * time.Second
	}

	clientID := strings.TrimSpace(cfg.ClientID)
	if clientID == "" {
		clientID = "workflow-api"
	}

	return &KafkaPublisher{
		writer: kafka.NewWriter(kafka.WriterConfig{
			Brokers:      brokers,
			Balancer:     &kafka.Hash{},
			RequiredAcks: int(kafka.RequireAll),
			BatchSize:    1,
			Async:        false,
			Dialer: &kafka.Dialer{
				Timeout:  publishTimeout,
				ClientID: clientID,
			},
		}),
	}, nil
}

// validateEvent checks routing identity before the network call. The payload
// is sent exactly as persisted; it is never reconstructed from live tables.
func validateEvent(event model.EventOutbox) error {
	if strings.TrimSpace(event.Topic) == "" {
		return &InvalidEventError{cause: ErrKafkaTopicMissing}
	}
	if len(event.PayloadJSON) == 0 || !json.Valid(event.PayloadJSON) {
		return &InvalidEventError{cause: ErrKafkaPayloadMissing}
	}
	if event.EventID == "" || event.CommandID == "" || event.BatchID == "" {
		return &InvalidEventError{
			cause: errors.New("kafka event identifiers are incomplete"),
		}
	}
	if event.PartitionKey != event.BatchID {
		return &InvalidEventError{
			cause: errors.New("kafka partition key must equal batch id"),
		}
	}
	if event.SchemaVersion != 1 {
		return &InvalidEventError{
			cause: errors.New("unsupported kafka schema version"),
		}
	}
	if event.SequenceInCommand == 0 {
		return &InvalidEventError{
			cause: errors.New("kafka event sequence must be positive"),
		}
	}
	if len(event.CorrelationID) == 0 || len(event.CorrelationID) > 128 {
		return &InvalidEventError{
			cause: errors.New("kafka correlation id is invalid"),
		}
	}

	for _, value := range []string{
		event.EventID,
		event.CommandID,
		event.BatchID,
		event.PartitionKey,
	} {
		parsed, err := uuid.Parse(value)
		if err != nil || parsed.String() != value {
			return &InvalidEventError{
				cause: errors.New("kafka identifier must be a lowercase uuid"),
			}
		}
	}

	return nil
}

func (p *KafkaPublisher) Publish(
	ctx context.Context,
	event model.EventOutbox,
) error {
	if p == nil || p.writer == nil {
		return ErrKafkaPublisherUnavailable
	}
	if err := validateEvent(event); err != nil {
		return err
	}

	return p.writer.WriteMessages(ctx, kafka.Message{
		Topic: event.Topic,
		Key:   []byte(event.PartitionKey),
		Value: event.PayloadJSON,
		Headers: []kafka.Header{
			{
				Key:   "event_id",
				Value: []byte(event.EventID),
			},
			{
				Key:   "event_type",
				Value: []byte(event.EventType),
			},
			{
				Key:   "schema_version",
				Value: []byte(strconv.FormatUint(uint64(event.SchemaVersion), 10)),
			},
			{
				Key:   "correlation_id",
				Value: []byte(event.CorrelationID),
			},
		},
	})
}

func (p *KafkaPublisher) Close() error {
	if p == nil || p.writer == nil {
		return nil
	}

	return p.writer.Close()
}
