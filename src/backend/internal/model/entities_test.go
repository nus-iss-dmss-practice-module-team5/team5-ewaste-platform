package model

import "testing"

func TestEntityTableNamesMatchLiquibaseSchema(t *testing.T) {
	tests := map[string]string{
		"organisation": (Organisation{}).TableName(),
		"role":         (Role{}).TableName(),
		"user":         (User{}).TableName(),
		"session":      (Session{}).TableName(),
	}
	expected := map[string]string{
		"organisation": "organisations",
		"role":         "roles",
		"user":         "users",
		"session":      "sessions",
	}
	for name, want := range expected {
		if tests[name] != want {
			t.Errorf("%s table: expected %q, got %q", name, want, tests[name])
		}
	}
}
