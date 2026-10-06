package controller

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"

	"workflow-api/internal/middleware"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
	"workflow-api/internal/service"
	"workflow-api/internal/token"
)

type timelineRepositoryStub struct {
	repository.WorkflowReadRepository
	entries []model.BatchTimelineEntry
	err     error
	page    repository.WorkflowReadPage
}

func (s *timelineRepositoryStub) ListBatchTimeline(_ context.Context, _ string, page repository.WorkflowReadPage) ([]model.BatchTimelineEntry, int64, error) {
	s.page = page
	return s.entries, int64(len(s.entries)), s.err
}

func timelineRouter(repo *timelineRepositoryStub, claims *token.Claims) *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.Use(middleware.CorrelationID(), func(c *gin.Context) {
		if claims != nil {
			c.Set(middleware.ClaimsKey, claims)
		}
	})
	reads := NewWorkflowReadController(service.NewWorkflowReadService(repo), nil)
	r.GET("/api/v1/audit/batches/:batch_id/timeline", reads.GetBatchTimeline)
	return r
}

func getTimeline(r *gin.Engine, query string) *httptest.ResponseRecorder {
	recorder := httptest.NewRecorder()
	r.ServeHTTP(recorder, httptest.NewRequest(http.MethodGet, "/api/v1/audit/batches/batch-1/timeline"+query, nil))
	return recorder
}

func auditorClaims() *token.Claims {
	return &token.Claims{UserID: "USR-002", RoleCode: "AUDITOR", OrganisationID: "PLATFORM"}
}

func TestGetBatchTimelineReturnsAPageOfEntriesToAnAuditor(t *testing.T) {
	repo := &timelineRepositoryStub{entries: []model.BatchTimelineEntry{{
		ID: "evt-1", ActorUserID: new("USR-010"), ActorName: new("Green Office Donor"),
		OrganisationID: new("DON-001"), OrganisationName: new("Green Office"),
		EventType: model.BatchAuditEventRequestSubmitted, FromStatus: model.BatchStatusDraft, ToStatus: model.BatchStatusSubmitted,
		BatchVersion: 2, OccurredAt: time.Date(2026, 10, 7, 1, 30, 0, 0, time.UTC), CorrelationID: "corr-1",
		DetailsJSON: []byte(`{"verification_hash":"donor-proof"}`),
	}}}

	recorder := getTimeline(timelineRouter(repo, auditorClaims()), "")

	if recorder.Code != http.StatusOK {
		t.Fatalf("status = %d, body = %s", recorder.Code, recorder.Body.String())
	}
	var body struct {
		Data          []map[string]any `json:"data"`
		Page          int              `json:"page"`
		PageSize      int              `json:"page_size"`
		TotalCount    int              `json:"total_count"`
		CorrelationID string           `json:"correlation_id"`
	}
	if err := json.Unmarshal(recorder.Body.Bytes(), &body); err != nil {
		t.Fatalf("decode body: %v", err)
	}
	if body.Page != 1 || body.PageSize != 100 || body.TotalCount != 1 || body.CorrelationID == "" {
		t.Fatalf("unexpected page: %s", recorder.Body.String())
	}
	if repo.page != (repository.WorkflowReadPage{Page: 1, PageSize: 100}) {
		t.Fatalf("default page = %+v, want the whole timeline in one page", repo.page)
	}
	want := map[string]any{
		"event_id": "evt-1", "occurred_at": "2026-10-07T01:30:00Z", "action": "RequestSubmitted",
		"from_status": "DRAFT", "to_status": "SUBMITTED", "result": "SUBMITTED", "batch_version": float64(2),
		"actor_user_id": "USR-010", "actor_name": "Green Office Donor",
		"organisation_id": "DON-001", "organisation_name": "Green Office", "correlation_id": "corr-1",
	}
	if len(body.Data) != 1 || len(body.Data[0]) != len(want) {
		t.Fatalf("unexpected entry: %s", recorder.Body.String())
	}
	for key, value := range want {
		if body.Data[0][key] != value {
			t.Fatalf("%s = %v, want %v", key, body.Data[0][key], value)
		}
	}
}

func TestGetBatchTimelineRejectsCallersAndInput(t *testing.T) {
	cases := []struct {
		name   string
		claims *token.Claims
		repo   *timelineRepositoryStub
		query  string
		status int
		code   string
	}{
		{"no session", nil, &timelineRepositoryStub{}, "", http.StatusUnauthorized, "AUTH_INVALID_SESSION"},
		{"donor", &token.Claims{UserID: "USR-010", RoleCode: "DONOR", OrganisationID: "DON-001"}, &timelineRepositoryStub{}, "", http.StatusForbidden, "FORBIDDEN"},
		{"recycler", &token.Claims{UserID: "USR-020", RoleCode: "RECYCLER", OrganisationID: "PROC-001"}, &timelineRepositoryStub{}, "", http.StatusForbidden, "FORBIDDEN"},
		{"unknown batch", auditorClaims(), &timelineRepositoryStub{err: repository.ErrWorkflowReadNotFound}, "", http.StatusNotFound, "NOT_FOUND"},
		{"page size above limit", auditorClaims(), &timelineRepositoryStub{}, "?page_size=101", http.StatusBadRequest, "INVALID_REQUEST"},
		{"page zero", auditorClaims(), &timelineRepositoryStub{}, "?page=0", http.StatusBadRequest, "INVALID_REQUEST"},
	}
	for _, tc := range cases {
		recorder := getTimeline(timelineRouter(tc.repo, tc.claims), tc.query)
		var body struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal(recorder.Body.Bytes(), &body)
		if recorder.Code != tc.status || body.Code != tc.code {
			t.Fatalf("%s: status = %d code = %q, want %d %q (body %s)", tc.name, recorder.Code, body.Code, tc.status, tc.code, recorder.Body.String())
		}
	}
}

func TestGetBatchTimelineHonoursPagingParameters(t *testing.T) {
	repo := &timelineRepositoryStub{}
	recorder := getTimeline(timelineRouter(repo, auditorClaims()), "?page=3&page_size=5")
	if recorder.Code != http.StatusOK || repo.page != (repository.WorkflowReadPage{Page: 3, PageSize: 5}) {
		t.Fatalf("status = %d page = %+v", recorder.Code, repo.page)
	}
}
