package eventbus

import (
	"crypto/tls"
	"testing"
	"time"

	"github.com/segmentio/kafka-go"

	"workflow-api/internal/config"
)

func TestNewKafkaPublisherConfiguresEventHubsTransport(t *testing.T) {
	publisher, err := NewKafkaPublisher(config.KafkaConfig{
		Brokers:        []string{"evh-ewaste-dev.servicebus.windows.net:9093"},
		TLSEnabled:     true,
		SASLMechanism:  "PLAIN",
		SASLUsername:   "$ConnectionString",
		SASLPassword:   "Endpoint=sb://evh-ewaste-dev.servicebus.windows.net/;SharedAccessKey=redacted",
		PublishTimeout: time.Second,
	})
	if err != nil {
		t.Fatalf("create Event Hubs publisher: %v", err)
	}

	transport, ok := publisher.writer.Transport.(*kafka.Transport)
	if !ok {
		t.Fatalf("expected kafka.Transport, got %T", publisher.writer.Transport)
	}
	if transport == nil || transport.TLS == nil {
		t.Fatal("expected TLS transport for Event Hubs")
	}
	if transport.TLS.MinVersion != tls.VersionTLS12 || transport.TLS.ServerName != "evh-ewaste-dev.servicebus.windows.net" {
		t.Fatalf("unexpected TLS configuration: %+v", transport.TLS)
	}
	if transport.SASL == nil || transport.SASL.Name() != "PLAIN" {
		t.Fatal("expected SASL/PLAIN authentication for Event Hubs")
	}
}

func TestNewKafkaPublisherRejectsIncompleteSASLCredentials(t *testing.T) {
	_, err := NewKafkaPublisher(config.KafkaConfig{
		Brokers:      []string{"localhost:9092"},
		SASLUsername: "$ConnectionString",
	})
	if err == nil {
		t.Fatal("expected incomplete SASL credentials to be rejected")
	}
}

func TestKafkaServerNameSupportsHostAndHostPort(t *testing.T) {
	if got := kafkaServerName("broker.example.com:9093"); got != "broker.example.com" {
		t.Fatalf("expected host without port, got %q", got)
	}
	if got := kafkaServerName("broker.example.com"); got != "broker.example.com" {
		t.Fatalf("expected host to remain unchanged, got %q", got)
	}
}
