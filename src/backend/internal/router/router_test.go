package router

import (
	"net/http"
	"net/http/httptest"
	"testing"
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
