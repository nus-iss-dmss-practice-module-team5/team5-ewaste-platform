package service

import (
	"testing"

	"workflow-api/internal/model"
)

func TestBatchToDTOExposesClaimEpochOnlyAfterClaim(t *testing.T) {
	batch := model.Batch{ID: "batch-1", Status: model.BatchStatusApproved, Version: 4, ClaimEpoch: 7}
	view := batchToDTO(&batch)
	if view.ClaimEpoch != "" {
		t.Fatalf("unclaimed batch exposed claim epoch %q", view.ClaimEpoch)
	}

	batch.CurrentClaimID = new("claim-1")
	view = batchToDTO(&batch)
	if view.ClaimEpoch != "7" {
		t.Fatalf("claimed batch claim epoch = %q, want 7", view.ClaimEpoch)
	}
}

func TestBatchToDTOExposesCollectorScopeID(t *testing.T) {
	scopeID := "scope-1"
	batch := model.Batch{
		ID:               "batch-1",
		Status:           model.BatchStatusApproved,
		Version:          4,
		CollectorScopeID: &scopeID,
	}

	view := batchToDTO(&batch)
	if view.CollectorScopeID != scopeID {
		t.Fatalf("collector scope id = %q, want %q", view.CollectorScopeID, scopeID)
	}
}

func TestOpportunityToDTOExposesClaimVersionAndEpoch(t *testing.T) {
	opportunity := model.WorkflowOpportunity{
		BatchID:    "batch-1",
		Status:     model.BatchStatusMatched,
		Version:    3,
		ClaimEpoch: 2,
	}

	view := opportunityToDTO(&opportunity)
	if view.Version != 3 {
		t.Fatalf("opportunity version = %d, want 3", view.Version)
	}
	if view.ClaimEpoch != "2" {
		t.Fatalf("opportunity claim epoch = %q, want 2", view.ClaimEpoch)
	}
}
