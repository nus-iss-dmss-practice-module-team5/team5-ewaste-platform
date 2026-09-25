package repository

import (
	"context"
	"testing"

	"github.com/DATA-DOG/go-sqlmock"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"

	"workflow-api/internal/model"
)

func newBatchRepositoryTestDB(t *testing.T) (*gorm.DB, sqlmock.Sqlmock) {
	t.Helper()

	sqlDB, mock, err := sqlmock.New()
	if err != nil {
		t.Fatalf("create sql mock: %v", err)
	}

	t.Cleanup(func() {
		_ = sqlDB.Close()
	})

	db, err := gorm.Open(mysql.New(mysql.Config{
		Conn:                      sqlDB,
		SkipInitializeWithVersion: true,
	}), &gorm.Config{})

	if err != nil {
		t.Fatalf("create gorm database: %v", err)
	}

	return db, mock
}

func TestGormBatchRepositoryTransactionRejectsNilCallback(t *testing.T) {
	db, _ := newBatchRepositoryTestDB(t)
	repo := NewGormBatchRepository(db)

	err := repo.Transaction(context.Background(), nil)

	if err == nil || err.Error() != "repository: transaction callback is nil" {
		t.Fatalf("expected nil callback error, got %v", err)
	}
}

func TestBatchTableNameMatchesDesign(t *testing.T) {
	if got := (model.Batch{}).TableName(); got != "ewaste_batches" {
		t.Fatalf("expected ewaste_batches, got %s", got)
	}
}
