package router

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"workflow-api/internal/docs"
	"workflow-api/internal/health"
)

func TestNewTestRouterHelloEndpoint(t *testing.T) {
	r := NewTestRouter()
	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/api/v1/hello", nil))
	if res.Code != http.StatusOK {
		t.Fatalf("expected 200, got %d", res.Code)
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
	r := NewAuthRouter(nil, nil, nil, nil, checker)

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
}

func TestAuthRouterReadinessReturns503WhenDependencyFails(t *testing.T) {
	checker := health.NewCheckerWithPingers(
		func(context.Context) error { return errors.New("mysql unavailable") },
		func(context.Context) error { return nil },
		time.Second,
	)
	r := NewAuthRouter(nil, nil, nil, nil, checker)

	res := httptest.NewRecorder()
	r.ServeHTTP(res, httptest.NewRequest(http.MethodGet, "/readyz", nil))
	if res.Code != http.StatusServiceUnavailable {
		t.Fatalf("expected readiness 503, got %d", res.Code)
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
