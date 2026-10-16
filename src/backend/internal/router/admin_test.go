package router

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"go.uber.org/zap"

	"workflow-api/internal/controller"
	"workflow-api/internal/health"
	"workflow-api/internal/model"
	"workflow-api/internal/service"
	"workflow-api/internal/token"
)

// adminSessions accepts any session whose id matches the user's, so each
// role below signs in with a token the middleware takes as valid.
type adminSessions struct {
	routerTestRepository
	roles map[string]string
}

func (s adminSessions) FindSession(_ context.Context, sessionID string) (*model.Session, error) {
	userID := strings.TrimPrefix(sessionID, "sid-")
	return &model.Session{SessionID: sessionID, UserID: userID, ExpiresAt: time.Now().Add(time.Hour)}, nil
}

func (s adminSessions) FindActiveUserByID(_ context.Context, userID string) (*model.User, error) {
	return &model.User{UserID: userID, RoleCode: s.roles[userID], Status: "ACTIVE"}, nil
}

type adminStatusRepo struct{ reads int }

func (r *adminStatusRepo) ValidateAdmin(context.Context, string) error { r.reads++; return nil }
func (r *adminStatusRepo) SummariseOutbox(context.Context, int) (*model.OutboxSummary, error) {
	r.reads++
	return &model.OutboxSummary{}, nil
}
func (r *adminStatusRepo) SummariseEvidence(context.Context) (*model.EvidenceSummary, error) {
	r.reads++
	return &model.EvidenceSummary{}, nil
}

func TestAdminPlatformStatusIsSystemAdminOnly(t *testing.T) {
	roles := map[string]string{
		"USR-005": "SYSTEM_ADMIN", "USR-002": "AUDITOR", "USR-003": "RECYCLER", "USR-001": "DONOR", "USR-004": "COLLECTOR",
	}
	sessions := adminSessions{roles: roles}
	tokens := token.NewService("router-test", "access-secret", "refresh-secret", "refresh-hash-secret", time.Minute, time.Hour)
	repo := &adminStatusRepo{}
	checker := health.NewCheckerWithPingers(func(context.Context) error { return nil }, func(context.Context) error { return nil }, time.Second)
	platform := service.NewPlatformStatusService(repo, checker, nil, service.PlatformStatusSettings{})
	r := newRouterTest(t, nil)
	RegisterAdmin(r, tokens, sessions, controller.NewPlatformStatusController(platform, zap.NewNop()))

	call := func(authorization string) (int, string) {
		req := httptest.NewRequest(http.MethodGet, "/api/v1/admin/platform-status", nil)
		if authorization != "" {
			req.Header.Set("Authorization", authorization)
		}
		res := httptest.NewRecorder()
		r.ServeHTTP(res, req)
		var body struct {
			Code string `json:"code"`
		}
		_ = json.Unmarshal(res.Body.Bytes(), &body)
		return res.Code, body.Code
	}
	bearer := func(userID string) string {
		access, _, _, _, err := tokens.Issue(userID, "sid-"+userID, roles[userID], "ORG", time.Now())
		if err != nil {
			t.Fatalf("issue token: %v", err)
		}
		return "Bearer " + access
	}

	for _, userID := range []string{"USR-002", "USR-003", "USR-001", "USR-004"} {
		if status, code := call(bearer(userID)); status != http.StatusForbidden || code != "FORBIDDEN" {
			t.Fatalf("%s: status = %d code = %q, want 403 FORBIDDEN", roles[userID], status, code)
		}
	}
	if repo.reads != 0 {
		t.Fatalf("a denied caller caused %d repository reads", repo.reads)
	}
	for name, header := range map[string]string{"no token": "", "tampered token": bearer("USR-005") + "x", "not bearer": "Basic abc"} {
		if status, _ := call(header); status != http.StatusUnauthorized {
			t.Fatalf("%s: status = %d, want 401", name, status)
		}
	}
	if status, _ := call(bearer("USR-005")); status != http.StatusOK {
		t.Fatalf("system admin: status = %d, want 200", status)
	}
}

// The Admin surface is read-only: no other method is routed.
func TestAdminPlatformStatusHasNoWriteMethods(t *testing.T) {
	r := newRouterTest(t, nil)
	tokens := token.NewService("router-test", "access-secret", "refresh-secret", "refresh-hash-secret", time.Minute, time.Hour)
	platform := service.NewPlatformStatusService(&adminStatusRepo{}, nil, nil, service.PlatformStatusSettings{})
	RegisterAdmin(r, tokens, routerTestRepository{}, controller.NewPlatformStatusController(platform, zap.NewNop()))

	for _, method := range []string{http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete} {
		res := httptest.NewRecorder()
		r.ServeHTTP(res, httptest.NewRequest(method, "/api/v1/admin/platform-status", nil))
		if res.Code != http.StatusNotFound {
			t.Fatalf("%s: status = %d, want 404", method, res.Code)
		}
	}
}
