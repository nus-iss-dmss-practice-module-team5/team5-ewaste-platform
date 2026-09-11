package router

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"

	"workflow-api/internal/controller"
	"workflow-api/internal/docs"
	"workflow-api/internal/health"
	"workflow-api/internal/model"
	"workflow-api/internal/repository"
	"workflow-api/internal/service"
	"workflow-api/internal/token"
)

type routerTestRepository struct{}

func (routerTestRepository) FindActiveUserByEmail(context.Context, string) (*model.User, error) {
	return nil, repository.ErrNotFound
}

func (routerTestRepository) FindActiveUserByID(context.Context, string) (*model.User, error) {
	return nil, repository.ErrNotFound
}

func (routerTestRepository) CreateLoginSession(context.Context, *model.User, *model.Session, time.Time) error {
	return nil
}

func (routerTestRepository) CreateLoginAudit(context.Context, *model.LoginAudit) error {
	return nil
}

func (routerTestRepository) FindSession(context.Context, string) (*model.Session, error) {
	return nil, repository.ErrNotFound
}

func (routerTestRepository) RotateSession(context.Context, string, string, string, string, time.Time, time.Time) error {
	return nil
}

func (routerTestRepository) RevokeSession(context.Context, string, string, string, time.Time) error {
	return nil
}

type routerTestLimiter struct{}

func (routerTestLimiter) Allow(context.Context, string) (bool, error) {
	return true, nil
}

func newRouterTest(t *testing.T, checker *health.Checker) *gin.Engine {
	t.Helper()
	repo := routerTestRepository{}
	tokens := token.NewService("router-test", "access-secret", "refresh-secret", "refresh-hash-secret", time.Minute, time.Hour)
	authService := service.NewAuthService(repo, tokens, zap.NewNop())
	authController := controller.NewAuthController(authService, zap.NewNop())
	return NewAuthRouter(authController, tokens, repo, routerTestLimiter{}, checker)
}

func TestNewTestRouterHelloEndpoint(t *testing.T) {
	r := NewTestRouter()
	res := httptest.NewRecorder()
	req := httptest.NewRequest(http.MethodGet, "/api/v1/hello", nil)
	req.Header.Set("Origin", "https://aca-ewaste-dev-ui.kindflower-300f4866.malaysiawest.azurecontainerapps.io")
	r.ServeHTTP(res, req)
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
	}
	if got := res.Header().Get("Access-Control-Allow-Origin"); got != req.Header.Get("Origin") {
		t.Fatalf("expected CORS allow-origin %q, got %q", req.Header.Get("Origin"), got)
	}
}

func TestNewTestRouterNotFoundEndpoint(t *testing.T) {
	r := NewTestRouter()
	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/missing", nil))
	if res.Code != http.StatusNotFound {
		t.Fatalf("expected 404, got %d", res.Code)
	}
}

func TestAuthRouterHealthEndpoints(t *testing.T) {
	checker := health.NewCheckerWithPingers(
		func(context.Context) error { return nil },
		func(context.Context) error { return nil },
		time.Second,
	)
	r := newRouterTest(t, checker)

	liveness := httptest.NewRecorder()
	r.ServeHTTP(liveness, httptest.NewRequest(http.MethodGet, "/healthz", nil))
	if liveness.Code != http.StatusOK {
		t.Fatalf("expected liveness 200, got %d", liveness.Code)
	}

	readiness := httptest.NewRecorder()
	r.ServeHTTP(readiness, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if readiness.Code != http.StatusOK {
		t.Fatalf("expected readiness 200, got %d", readiness.Code)
	}
	var report health.Report
	if err := json.Unmarshal(readiness.Body.Bytes(), &report); err != nil {
		t.Fatalf("decode readiness report: %v", err)
	}
	if report.Status != "ready" || report.MySQL != "ok" || report.Redis != "ok" {
		t.Fatalf("unexpected readiness report: %+v", report)
	}
}

func TestAuthRouterReadinessReturns503WhenDependencyFails(t *testing.T) {
	checker := health.NewCheckerWithPingers(
		func(context.Context) error { return errors.New("mysql unavailable") },
		func(context.Context) error { return nil },
		time.Second,
	)
	r := newRouterTest(t, checker)

	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if res.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected readiness 503, got %d", res.Code)
	}
	var report health.Report
	if err := json.Unmarshal(res.Body.Bytes(), &report); err != nil {
		t.Fatalf("decode readiness failure report: %v", err)
	}
	if report.Status != "not_ready" || report.MySQL != "unavailable" || report.Redis != "ok" {
		t.Fatalf("unexpected readiness failure report: %+v", report)
	}
}

func TestDocsExposeOpenAPISpecAndSwaggerUI(t *testing.T) {
	r := NewTestRouter()
	docs.Register(r)

	spec := httptest.NewRecorder()
	r.ServeHTTP(spec, httptest.NewRequest(http.MethodGet, "/openapi.yaml", nil))
	if spec.Code != http.StatusOK {
		t.Fatalf("expected OpenAPI 200, got %d", spec.Code)
	}
	if spec.Header().Get("Content-Type") != "application/yaml; charset=utf-8" {
		t.Fatalf("unexpected OpenAPI content type: %q", spec.Header().Get("Content-Type"))
	}

	ui := httptest.NewRecorder()
	r.ServeHTTP(ui, httptest.NewRequest(http.MethodGet, "/docs/", nil))
	if ui.Code != http.StatusOK {
		t.Fatalf("expected Swagger UI 200, got %d", ui.Code)
	}
}
