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
auth:
  access_ttl: "10m"
  refresh_ttl: "2h"
`)
	if err := os.WriteFile(configPath, contents, 0o600); err != nil {
		t.Fatalf("write test config: %v", err)
	}
	t.Setenv("EWASTE_SERVER_PORT", ":9191")

	cfg, err := Load(configPath)
	if err != nil {
		t.Fatalf("load config: %v", err)
	}
	if cfg.Server.Port != ":9191" {
		t.Fatalf("expected environment override, got %q", cfg.Server.Port)
	}
	if cfg.Auth.AccessTTL.Minutes() != 10 || cfg.Auth.RefreshTTL.Hours() != 2 {
		t.Fatalf("expected durations from config file, got access=%s refresh=%s", cfg.Auth.AccessTTL, cfg.Auth.RefreshTTL)
	}
}

func TestApplyTestModeUsesLocalDependencies(t *testing.T) {
	cfg := Config{Redis: RedisConfig{Address: ""}}
	if err := cfg.ApplyMode(ModeTest); err != nil {
		t.Fatalf("apply test mode: %v", err)
	}
	if cfg.Database.DSN == "" || cfg.Redis.Address != "localhost:6379" {
		t.Fatalf("expected localhost dependency defaults: %+v", cfg)
	}
}
