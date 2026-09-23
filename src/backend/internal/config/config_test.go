package config

import (
	"os"
	"path/filepath"
	"testing"
)

func TestLoadReadsConfigFileAndEnvironmentOverrides(t *testing.T) {
	configPath := filepath.Join(t.TempDir(), "config.yaml")
	contents := []byte(`
server:
  port: ":9090"
database:
  host: "mysql"
  port: 3306
  name: "ewaste"
  user: "ewaste_app"
auth:
  access_ttl: "10m"
  refresh_ttl: "2h"
`)
	if err := os.WriteFile(configPath, contents, 0o600); err != nil {
		t.Fatalf("write test config: %v", err)
	}
	t.Setenv("MYSQL_PASSWORD", "db-secret")
	t.Setenv("REDIS_PASSWORD", "redis-secret")
	t.Setenv("EWASTE_MODE", "production")
	t.Setenv("EWASTE_SERVER_PORT", ":8181")
	t.Setenv("EWASTE_SERVER_ALLOWED_ORIGINS", "http://localhost:3000,https://example.com")
	t.Setenv("EWASTE_DATABASE_HOST", "azure-mysql")
	t.Setenv("EWASTE_DATABASE_PORT", "3306")
	t.Setenv("EWASTE_DATABASE_NAME", "ewastedb")
	t.Setenv("EWASTE_DATABASE_USER", "ewasteadmin")
	t.Setenv("EWASTE_REDIS_ADDRESS", "azure-redis:6380")
	t.Setenv("EWASTE_REDIS_DB", "1")
	t.Setenv("EWASTE_REDIS_TLS_ENABLED", "true")
	t.Setenv("EWASTE_AUTH_ISSUER", "integration-api")
	t.Setenv("EWASTE_AUTH_ACCESS_TTL", "20m")
	t.Setenv("EWASTE_AUTH_REFRESH_TTL", "3h")
	t.Setenv("EWASTE_RATE_LIMIT_REQUESTS", "25")
	t.Setenv("EWASTE_RATE_LIMIT_WINDOW", "2m")
	t.Setenv("EWASTE_KAFKA_ENABLED", "true")
	t.Setenv("EWASTE_KAFKA_BROKERS", "evh-ewaste-dev.servicebus.windows.net:9093")
	t.Setenv("EWASTE_KAFKA_TLS_ENABLED", "true")
	t.Setenv("EWASTE_KAFKA_SASL_MECHANISM", "PLAIN")
	t.Setenv("EWASTE_KAFKA_SASL_USERNAME", "$ConnectionString")
	t.Setenv("KAFKA_CONNECTION_STRING", "Endpoint=sb://evh-ewaste-dev.servicebus.windows.net/;SharedAccessKeyName=auth-ewaste-workload;SharedAccessKey=redacted")

	cfg, err := Load(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Server.Port != ":8181" {
		t.Fatalf("expected server port from environment, got %q", cfg.Server.Port)
	}
	if len(cfg.Server.AllowedOrigins) != 2 || cfg.Server.AllowedOrigins[0] != "http://localhost:3000" || cfg.Server.AllowedOrigins[1] != "https://example.com" {
		t.Fatalf("expected configured CORS origins, got %#v", cfg.Server.AllowedOrigins)
	}
	if cfg.Mode != ModeProduction || cfg.Database.Host != "azure-mysql" || cfg.Database.Port != 3306 || cfg.Database.Name != "ewastedb" || cfg.Database.User != "ewasteadmin" {
		t.Fatalf("expected database and mode environment values, got mode=%q database=%+v", cfg.Mode, cfg.Database)
	}
	if cfg.Database.Password != "db-secret" || cfg.Redis.Password != "redis-secret" || cfg.Redis.Address != "azure-redis:6380" || cfg.Redis.DB != 1 || !cfg.Redis.TLSEnabled {
		t.Fatalf("expected credential environment values, got database=%q redis=%q", cfg.Database.Password, cfg.Redis.Password)
	}
	if cfg.Auth.Issuer != "integration-api" || cfg.Auth.AccessTTL.Minutes() != 20 || cfg.Auth.RefreshTTL.Hours() != 3 {
		t.Fatalf("expected auth environment values, got issuer=%q access=%s refresh=%s", cfg.Auth.Issuer, cfg.Auth.AccessTTL, cfg.Auth.RefreshTTL)
	}
	if cfg.RateLimit.Requests != 25 || cfg.RateLimit.Window.Minutes() != 2 {
		t.Fatalf("expected rate limit environment values, got requests=%d window=%s", cfg.RateLimit.Requests, cfg.RateLimit.Window)
	}
	if !cfg.Kafka.Enabled || len(cfg.Kafka.Brokers) != 1 || cfg.Kafka.Brokers[0] != "evh-ewaste-dev.servicebus.windows.net:9093" || !cfg.Kafka.TLSEnabled || cfg.Kafka.SASLMechanism != "PLAIN" || cfg.Kafka.SASLUsername != "$ConnectionString" {
		t.Fatalf("expected Event Hubs Kafka connection settings, got %+v", cfg.Kafka)
	}
	if cfg.Kafka.SASLPassword == "" {
		t.Fatal("expected Kafka connection string from KAFKA_CONNECTION_STRING")
	}
}

func TestApplyTestModeUsesLocalDependencies(t *testing.T) {
	cfg := Config{Redis: RedisConfig{Address: ""}}
	if err := cfg.ApplyMode(ModeTest); err != nil {
		t.Fatalf("apply test mode: %v", err)
	}
	if cfg.Database.Host != "localhost" || cfg.Database.Port != 3307 || cfg.Redis.Address != "localhost:6379" {
		t.Fatalf("expected localhost dependency defaults: %+v", cfg)
	}
}
