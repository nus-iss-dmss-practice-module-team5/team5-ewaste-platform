package service

import (
	"context"
	"errors"
	"testing"
	"time"

	"workflow-api/internal/model"
	"workflow-api/internal/repository"
)

type auditReadRepositoryStub struct {
	timeline  []*model.BatchAuditEvent
	anomalies []*model.BatchAnomaly
	impact    []*model.ImpactReadResult
}

func (s *auditReadRepositoryStub) FindAuditTimeline(context.Context, string, repository.WorkflowReadScope, repository.WorkflowReadPage) ([]*model.BatchAuditEvent, int64, error) {
	return s.timeline, int64(len(s.timeline)), nil
}

func (s *auditReadRepositoryStub) FindAuditAnomalies(context.Context, string, repository.WorkflowReadScope, repository.WorkflowReadPage) ([]*model.BatchAnomaly, int64, error) {
	return s.anomalies, int64(len(s.anomalies)), nil
}

func (s *auditReadRepositoryStub) ListImpactResults(context.Context, repository.WorkflowReadScope) ([]*model.ImpactReadResult, error) {
	return s.impact, nil
}

func TestAuditorReadServiceExposesTimelineAnomaliesAndImpact(t *testing.T) {
	now := time.Date(2026, 10, 6, 12, 0, 0, 0, time.UTC)
	actor := WorkflowReadActor{UserID: "auditor-1", RoleCode: "AUDITOR"}
	service := NewAuditorReadService(&auditReadRepositoryStub{
		timeline: []*model.BatchAuditEvent{{
			ID: "audit-1", BatchID: "batch-1", CommandID: "command-1", EventType: model.BatchAuditEventAnalyticsCompleted,
			FromStatus: model.BatchStatusRecycled, ToStatus: model.BatchStatusCompleted, BatchVersion: 9,
			SequenceInCommand: 1, OccurredAt: now, CorrelationID: "corr-1", DetailsJSON: []byte(`{"rule_version":"d3-v1"}`),
		}},
		anomalies: []*model.BatchAnomaly{{AnomalyID: "anomaly-1", BatchID: "batch-1", ResultID: "result-1", Code: model.AnomalyMissingOutcome, DetectedAt: now}},
		impact: []*model.ImpactReadResult{{
			ResultID: "result-1", BatchID: "batch-1", SourceEventID: "event-1", SourceEventVersion: 8,
			ReceiptID: "receipt-1", ReceiptVersion: 1, TreatmentID: "treatment-1", TreatmentVersion: 1,
			RuleVersion: "d3-v1", InputHash: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
			DataQuality: model.AnalyticsDataQualityMissing, MetricsJSON: []byte(`{"declared_weight_kg":"11.00"}`),
			AnomalyCodes: []string{string(model.AnomalyMissingOutcome)}, AcknowledgedAt: now,
		}},
	})

	timeline, err := service.Timeline(context.Background(), "batch-1", actor, WorkflowReadPage{Page: 1, PageSize: 100})
	if err != nil || timeline.TotalCount != 1 || len(timeline.Data) != 1 || timeline.Data[0].ToStatus != string(model.BatchStatusCompleted) {
		t.Fatalf("unexpected timeline: %v %+v", err, timeline)
	}
	anomalies, err := service.Anomalies(context.Background(), "batch-1", actor, WorkflowReadPage{Page: 1, PageSize: 100})
	if err != nil || anomalies.TotalCount != 1 || len(anomalies.Data) != 1 || anomalies.Data[0].Code != string(model.AnomalyMissingOutcome) {
		t.Fatalf("unexpected anomalies: %v %+v", err, anomalies)
	}
	impact, err := service.Impact(context.Background(), actor)
	if err != nil || impact.TotalCount != 1 || len(impact.Items) != 1 || impact.Items[0].DataQuality != string(model.AnalyticsDataQualityMissing) {
		t.Fatalf("unexpected impact: %v %+v", err, impact)
	}
}

func TestAuditorReadServiceRejectsNonAuditor(t *testing.T) {
	service := NewAuditorReadService(&auditReadRepositoryStub{})
	if _, err := service.Timeline(context.Background(), "batch-1", WorkflowReadActor{UserID: "user-1", RoleCode: "RECYCLER"}, WorkflowReadPage{Page: 1, PageSize: 100}); !errors.Is(err, ErrWorkflowReadForbidden) {
		t.Fatalf("timeline error = %v, want forbidden", err)
	}
	if _, err := service.Impact(context.Background(), WorkflowReadActor{UserID: "user-1", RoleCode: "SYSTEM_ADMIN"}); !errors.Is(err, ErrWorkflowReadForbidden) {
		t.Fatalf("impact error = %v, want forbidden", err)
	}
}
