package logger

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"workflow-api/internal/config"
)

func TestNewWritesJSONToRotatingFile(t *testing.T) {
	logPath := filepath.Join(t.TempDir(), "workflow-api.log")
	log, err := New(config.LoggingConfig{
		Level: "info", FilePath: logPath, MaxSizeMB: 1, MaxBackups: 1, MaxAgeDays: 1, Console: false,
	})
	if err != nil {
		t.Fatalf("create logger: %v", err)
	}
	log.Info("test event")
	if err := log.Sync(); err != nil {
		t.Fatalf("sync logger: %v", err)
	}

	contents, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read log file: %v", err)
	}
	if !strings.Contains(string(contents), `"msg":"test event"`) {
		t.Fatalf("expected JSON log entry, got %s", contents)
	}
}
