package repository

import (
	"context"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestSummariseOutboxReadsMetadataOnly(t *testing.T) {
	db, mock := newBatchRepositoryTestDB(t)
	oldest := time.Date(2026, 10, 21, 13, 0, 0, 0, time.UTC)
	created := time.Date(2026, 10, 21, 13, 41, 0, 0, time.UTC)
	mock.ExpectQuery(`SELECT COUNT\(\*\) AS count, MIN\(created_at\) AS oldest FROM .event_outbox. WHERE publish_state = \?`).
		WithArgs("PENDING").
		WillReturnRows(sqlmock.NewRows([]string{"count", "oldest"}).AddRow(4, oldest))
	mock.ExpectQuery(`SELECT count\(\*\) FROM .event_outbox. WHERE publish_state = \?`).
		WithArgs("QUARANTINED").
		WillReturnRows(sqlmock.NewRows([]string{"count(*)"}).AddRow(2))
	// The column list is the guard: payload_json must never be selected.
	mock.ExpectQuery("SELECT .event_type.,.schema_version.,.batch_id.,.attempt_count.,.last_error_code.,.created_at.,.correlation_id. FROM .event_outbox. "+
		`WHERE publish_state = \? ORDER BY created_at DESC, event_id DESC LIMIT \?`).
		WithArgs("QUARANTINED", 5).
		WillReturnRows(sqlmock.NewRows([]string{"event_type", "schema_version", "batch_id", "attempt_count", "last_error_code", "created_at", "correlation_id"}).
			AddRow("TreatmentRecorded", 1, "ae95ae4f", 8, "BROKER_TIMEOUT", created, "corr-8f31c2"))

	summary, err := NewGormPlatformStatusRepository(db).SummariseOutbox(context.Background(), 5)

	if err != nil {
		t.Fatalf("summarise outbox: %v", err)
	}
	if summary.Pending != 4 || !summary.OldestPendingCreatedAt.Equal(oldest) || summary.Quarantined != 2 || len(summary.RecentQuarantined) != 1 {
		t.Fatalf("summary = %+v", summary)
	}
	if got := summary.RecentQuarantined[0]; got.BatchID != "ae95ae4f" || *got.LastErrorCode != "BROKER_TIMEOUT" || got.AttemptCount != 8 {
		t.Fatalf("event = %+v", got)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestSummariseOutboxSkipsTheListWhenNothingIsQuarantined(t *testing.T) {
	db, mock := newBatchRepositoryTestDB(t)
	mock.ExpectQuery(`MIN\(created_at\)`).WillReturnRows(sqlmock.NewRows([]string{"count", "oldest"}).AddRow(0, nil))
	mock.ExpectQuery(`SELECT count\(\*\) FROM .event_outbox.`).WillReturnRows(sqlmock.NewRows([]string{"count(*)"}).AddRow(0))

	summary, err := NewGormPlatformStatusRepository(db).SummariseOutbox(context.Background(), 5)

	if err != nil || summary.OldestPendingCreatedAt != nil || summary.RecentQuarantined == nil {
		t.Fatalf("summary = %+v err = %v", summary, err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestSummariseEvidenceCountsCompletedBatchesOnly(t *testing.T) {
	db, mock := newBatchRepositoryTestDB(t)
	mock.ExpectQuery(`COUNT\(\*\) AS completed,.*EXISTS \(SELECT 1 FROM batch_evidence AS e WHERE e\.batch_id = b\.id\).*FROM ewaste_batches AS b WHERE b\.status = \?`).
		WithArgs("COMPLETED").
		WillReturnRows(sqlmock.NewRows([]string{"completed", "with_evidence"}).AddRow(128, 120))

	summary, err := NewGormPlatformStatusRepository(db).SummariseEvidence(context.Background())

	if err != nil || summary.CompletedBatches != 128 || summary.WithEvidence != 120 {
		t.Fatalf("summary = %+v err = %v", summary, err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}

func TestValidateAdminRequiresAnActivePlatformAdmin(t *testing.T) {
	db, mock := newBatchRepositoryTestDB(t)
	mock.ExpectQuery(auditorCheckSQL + `.*u\.role_code = 'SYSTEM_ADMIN'`).WithArgs("USR-005").
		WillReturnRows(sqlmock.NewRows([]string{"count(*)"}).AddRow(0))

	if err := NewGormPlatformStatusRepository(db).ValidateAdmin(context.Background(), "USR-005"); err != ErrWorkflowReadForbidden {
		t.Fatalf("err = %v, want forbidden", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatal(err)
	}
}
