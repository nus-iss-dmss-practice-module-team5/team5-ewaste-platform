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

	cfg, err := Load(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Server.Port != ":8181" {
		t.Fatalf("expected server port from environment, got %q", cfg.Server.Port)
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
