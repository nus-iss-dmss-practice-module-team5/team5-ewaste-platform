package model

import (
	"testing"
	"time"
)

func TestEntityTableNamesMatchLiquibaseSchema(t *testing.T) {
	tests := map[string]string{
		"organisation": (Organisation{}).TableName(),
		"role":         (Role{}).TableName(),
		"user":         (User{}).TableName(),
		"session":      (Session{}).TableName(),
		"login_audit":  (LoginAudit{}).TableName(),
	}
	expected := map[string]string{
		"organisation": "organisations",
		"role":         "roles",
		"user":         "users",
		"session":      "sessions",
		"login_audit":  "login_audit",
	}
	for name, want := range expected {
		if tests[name] != want {
			t.Errorf("%s table: expected %q, got %q", name, want, tests[name])
		}
	}
}

func TestSessionIsActiveUsesRevocationState(t *testing.T) {
	now := time.Now().UTC()
	active := Session{ExpiresAt: now.Add(time.Minute)}
	if !active.IsActive(now) {
		t.Fatal("expected unrevoked, unexpired session to be active")
	}
	active.RevokedAt = new(now.Add(-time.Second))
	if active.IsActive(now) {
		t.Fatal("expected revoked session to be inactive")
	}
}
