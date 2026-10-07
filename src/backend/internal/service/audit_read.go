package service

import (
	"context"
	"encoding/json"
	"errors"
	"strings"

	"workflow-api/internal/dto"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
)

type AuditorReadService struct {
	repository repository.AuditorReadRepository
}

type AuditTimelineListResult struct {
	Data       []dto.AuditTimelineView
	Page       int
	PageSize   int
	TotalCount int64
}

type AuditAnomalyListResult struct {
	Data       []dto.AnomalyView
	Page       int
	PageSize   int
	TotalCount int64
}

func NewAuditorReadService(repo repository.AuditorReadRepository) *AuditorReadService {
	return &AuditorReadService{repository: repo}
}

func (s *AuditorReadService) Timeline(ctx context.Context, batchID string, actor WorkflowReadActor, page WorkflowReadPage) (AuditTimelineListResult, error) {
	if strings.TrimSpace(batchID) == "" || !isRole(actor.RoleCode, "AUDITOR") {
		return AuditTimelineListResult{}, ErrWorkflowReadForbidden
	}
	if err := validatePage(page); err != nil {
		return AuditTimelineListResult{}, err
	}
	events, total, err := s.repository.FindAuditTimeline(ctx, batchID, toRepositoryScope(actor), toRepositoryPage(page))
	if err != nil {
		return AuditTimelineListResult{}, mapWorkflowReadRepositoryError(err)
	}
	result := AuditTimelineListResult{Data: make([]dto.AuditTimelineView, 0, len(events)), Page: page.Page, PageSize: page.PageSize, TotalCount: total}
	for _, event := range events {
		result.Data = append(result.Data, auditEventToDTO(event))
	}
	return result, nil
}

func (s *AuditorReadService) Anomalies(ctx context.Context, batchID string, actor WorkflowReadActor, page WorkflowReadPage) (AuditAnomalyListResult, error) {
	if strings.TrimSpace(batchID) == "" || !isRole(actor.RoleCode, "AUDITOR") {
		return AuditAnomalyListResult{}, ErrWorkflowReadForbidden
	}
	if err := validatePage(page); err != nil {
		return AuditAnomalyListResult{}, err
	}
	anomalies, total, err := s.repository.FindAuditAnomalies(ctx, batchID, toRepositoryScope(actor), toRepositoryPage(page))
	if err != nil {
		return AuditAnomalyListResult{}, mapWorkflowReadRepositoryError(err)
	}
	result := AuditAnomalyListResult{Data: make([]dto.AnomalyView, 0, len(anomalies)), Page: page.Page, PageSize: page.PageSize, TotalCount: total}
	for _, anomaly := range anomalies {
		result.Data = append(result.Data, anomalyToDTO(anomaly))
	}
	return result, nil
}

func (s *AuditorReadService) Impact(ctx context.Context, actor WorkflowReadActor) (dto.ImpactCollectionView, error) {
	if !isRole(actor.RoleCode, "AUDITOR") {
		return dto.ImpactCollectionView{}, ErrWorkflowReadForbidden
	}
	items, err := s.repository.ListImpactResults(ctx, toRepositoryScope(actor))
	if err != nil {
		return dto.ImpactCollectionView{}, mapWorkflowReadRepositoryError(err)
	}
	result := dto.ImpactCollectionView{Items: make([]dto.ImpactResultView, 0, len(items)), TotalCount: int64(len(items))}
	for _, item := range items {
		view, err := impactToDTO(item)
		if err != nil {
			return dto.ImpactCollectionView{}, err
		}
		result.Items = append(result.Items, view)
	}
	return result, nil
}

func auditEventToDTO(event *model.BatchAuditEvent) dto.AuditTimelineView {
	details := map[string]any{}
	if len(event.DetailsJSON) > 0 {
		if err := json.Unmarshal(event.DetailsJSON, &details); err != nil {
			details = map[string]any{"raw": string(event.DetailsJSON)}
		}
	}
	return dto.AuditTimelineView{
		AuditID: event.ID, BatchID: event.BatchID, CommandID: event.CommandID,
		ActorUserID: event.ActorUserID, ActorOrganisation: event.ActorOrganizationID,
		ServicePrincipal: event.ServicePrincipal, EventType: event.EventType,
		FromStatus: string(event.FromStatus), ToStatus: string(event.ToStatus),
		BatchVersion: event.BatchVersion, Sequence: event.SequenceInCommand,
		OccurredAt: event.OccurredAt, CorrelationID: event.CorrelationID, Details: details,
	}
}

func anomalyToDTO(anomaly *model.BatchAnomaly) dto.AnomalyView {
	return dto.AnomalyView{
		AnomalyID: anomaly.AnomalyID, BatchID: anomaly.BatchID, ResultID: anomaly.ResultID,
		Code: string(anomaly.Code), DeclaredValue: anomaly.DeclaredValue,
		ActualValue: anomaly.ActualValue, DeltaKg: anomaly.DeltaKg, DetectedAt: anomaly.DetectedAt,
	}
}

func impactToDTO(result *model.ImpactReadResult) (dto.ImpactResultView, error) {
	var metrics dto.AnalyticsMetrics
	if len(result.MetricsJSON) > 0 {
		if err := json.Unmarshal(result.MetricsJSON, &metrics); err != nil {
			return dto.ImpactResultView{}, errors.New("workflow read: stored analytics metrics are invalid")
		}
	}
	return dto.ImpactResultView{
		ResultID: result.ResultID, BatchID: result.BatchID, SourceEventID: result.SourceEventID,
		SourceEventVersion: result.SourceEventVersion, ReceiptID: result.ReceiptID,
		ReceiptVersion: result.ReceiptVersion, TreatmentID: result.TreatmentID,
		TreatmentVersion: result.TreatmentVersion, RuleVersion: result.RuleVersion,
		InputHash: result.InputHash, DataQuality: string(result.DataQuality), Metrics: metrics,
		AnomalyCodes: append([]string{}, result.AnomalyCodes...), AcknowledgedAt: result.AcknowledgedAt,
	}, nil
}
