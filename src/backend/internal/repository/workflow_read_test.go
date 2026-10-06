package repository

import (
	"context"
	"errors"
	"regexp"
	"testing"
	"time"

	"github.com/DATA-DOG/go-sqlmock"
)

func TestListBatchTimelineReturnsNotFoundForAnUnknownBatch(t *testing.T) {
	db, mock := newBatchRepositoryTestDB(t)
	mock.ExpectQuery(regexp.QuoteMeta("SELECT count(*) FROM `ewaste_batches` WHERE id = ?")).
		WithArgs("missing").
		WillReturnRows(sqlmock.NewRows([]string{"count(*)"}).AddRow(0))

	_, _, err := NewGormWorkflowReadRepository(db).ListBatchTimeline(context.Background(), "missing", WorkflowReadPage{Page: 1, PageSize: 100})

	if !errors.Is(err, ErrWorkflowReadNotFound) {
		t.Fatalf("error = %v, want not found", err)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatalf("unexpected queries: %v", err)
	}
}

func TestListBatchTimelineReadsOneBatchOldestFirstWithPaging(t *testing.T) {
	db, mock := newBatchRepositoryTestDB(t)
	occurredAt := time.Date(2026, 10, 7, 1, 30, 0, 0, time.UTC)
	mock.ExpectQuery(regexp.QuoteMeta("SELECT count(*) FROM `ewaste_batches` WHERE id = ?")).
		WithArgs("batch-1").
		WillReturnRows(sqlmock.NewRows([]string{"count(*)"}).AddRow(1))
	mock.ExpectQuery(regexp.QuoteMeta("SELECT count(*) FROM `batch_audit_events` WHERE batch_id = ?")).
		WithArgs("batch-1").
		WillReturnRows(sqlmock.NewRows([]string{"count(*)"}).AddRow(5))
	mock.ExpectQuery(
		`FROM batch_audit_events AS a `+
			`LEFT JOIN users AS u ON u\.user_id = a\.actor_user_id `+
			`LEFT JOIN organisations AS o ON o\.organisation_id = a\.actor_org_id `+
			`WHERE a\.batch_id = \? `+
			`ORDER BY a\.occurred_at ASC, a\.batch_version ASC, a\.sequence_in_command ASC, a\.id ASC `+
			`LIMIT \? OFFSET \?`,
	).
		WithArgs("batch-1", 2, 2).
		WillReturnRows(sqlmock.NewRows([]string{
			"id", "actor_user_id", "actor_name", "actor_org_id", "organisation_name", "service_principal",
			"event_type", "from_status", "to_status", "batch_version", "sequence_in_command",
			"occurred_at", "correlation_id", "details_json",
		}).
			AddRow("evt-3", "USR-010", "Green Office Donor", "DON-001", "Green Office", nil,
				"RequestSubmitted", "DRAFT", "SUBMITTED", 2, 1, occurredAt, "corr-3", []byte(`{}`)).
			AddRow("evt-4", nil, nil, nil, nil, "matching-worker",
				"MatchingCompleted", "SUBMITTED", "MATCHED", 3, 1, occurredAt.Add(time.Second), "corr-4", []byte(`{}`)))

	entries, total, err := NewGormWorkflowReadRepository(db).ListBatchTimeline(context.Background(), "batch-1", WorkflowReadPage{Page: 2, PageSize: 2})

	if err != nil {
		t.Fatalf("list timeline: %v", err)
	}
	if total != 5 || len(entries) != 2 {
		t.Fatalf("total = %d, entries = %d", total, len(entries))
	}
	first, second := entries[0], entries[1]
	if first.ID != "evt-3" || first.ActorName == nil || *first.ActorName != "Green Office Donor" || first.OrganisationName == nil || *first.OrganisationName != "Green Office" || first.ServicePrincipal != nil {
		t.Fatalf("unexpected person entry: %+v", first)
	}
	if second.ID != "evt-4" || second.ActorUserID != nil || second.ServicePrincipal == nil || *second.ServicePrincipal != "matching-worker" || second.ToStatus != "MATCHED" {
		t.Fatalf("unexpected service entry: %+v", second)
	}
	if err := mock.ExpectationsWereMet(); err != nil {
		t.Fatalf("unexpected queries: %v", err)
	}
}
