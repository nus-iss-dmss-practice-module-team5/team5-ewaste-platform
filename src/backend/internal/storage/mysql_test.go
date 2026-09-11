package storage

import (
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"

	"workflow-api/internal/config"
)

func TestBuildMySQLDSNSeparatesConnectionSettings(t *testing.T) {
	dsn := buildMySQLDSN(config.DatabaseConfig{
		Host: "mysql", Port: 3306, Name: "ewaste", User: "ewaste_app", Password: "secret",
	})

	for _, expected := range []string{
		"ewaste_app:secret@tcp(mysql:3306)/ewaste",
		"charset=utf8mb4",
		"parseTime=true",
		"allowNativePasswords=true",
		"tls=preferred",
	} {
		if !contains(dsn, expected) {
			t.Fatalf("expected DSN to contain %q, got %q", expected, dsn)
		}
	}
}

func contains(value, fragment string) bool {
	for i := 0; i+len(fragment) <= len(value); i++ {
		if value[i:i+len(fragment)] == fragment {
			return true
		}
	}
	return false
}

func TestPingMySQLUsesDatabaseConnection(t *testing.T) {
	sqlDB, mock, err := sqlmock.New(sqlmock.MonitorPingsOption(true))
	if err != nil {
		t.Fatalf("create SQL mock: %v", err)
	}
	t.Cleanup(func() {
		if err := sqlDB.Close(); err != nil {
			t.Errorf("close SQL mock: %v", err)
		}
		if err := mock.ExpectationsWereMet(); err != nil {
			t.Errorf("check SQL expectations: %v", err)
		}
	})
	mock.ExpectPing()
	mock.ExpectClose()

	gormDB, err := gorm.Open(mysql.New(mysql.Config{
		Conn:                      sqlDB,
		SkipInitializeWithVersion: true,
	}), &gorm.Config{})
	if err != nil {
		t.Fatalf("open gorm DB: %v", err)
	}

	if err := PingMySQL(gormDB, time.Second); err != nil {
		t.Fatalf("ping failed: %v", err)
	}
}
