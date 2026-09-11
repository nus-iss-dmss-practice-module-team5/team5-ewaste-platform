package dto

import (
	"encoding/json"
	"testing"
)

func TestTokenResponseUsesAPIFieldNames(t *testing.T) {
	payload, err := json.Marshal(TokenResponse{
		AccessToken: "access", RefreshToken: "refresh", TokenType: "Bearer", ExpiresIn: 900, RefreshExpiresIn: 86400,
	})
	if err != nil {
		t.Fatalf("marshal token response: %v", err)
	}
	expected := `{"accessToken":"access","refreshToken":"refresh","tokenType":"Bearer","expiresIn":900,"refreshExpiresIn":86400}`
	if string(payload) != expected {
		t.Fatalf("expected %s, got %s", expected, payload)
	}
}

func TestErrorResponseUsesCorrelationIdField(t *testing.T) {
	payload, err := json.Marshal(ErrorResponse{Code: "AUTH_INVALID_REQUEST", Message: "invalid request", CorrelationID: "corr-001"})
	if err != nil {
		t.Fatalf("marshal error response: %v", err)
	}
	if string(payload) != `{"code":"AUTH_INVALID_REQUEST","message":"invalid request","correlationId":"corr-001"}` {
		t.Fatalf("unexpected error response: %s", payload)
	}
}
