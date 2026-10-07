package dto

import (
	"encoding/json"
	"testing"
)

func TestCompletionMutationResultSerializesRequiredEventFields(t *testing.T) {
	raw, err := json.Marshal(CompletionMutationResult{})
	if err != nil {
		t.Fatalf("marshal completion response: %v", err)
	}

	var payload map[string]any
	if err := json.Unmarshal(raw, &payload); err != nil {
		t.Fatalf("decode completion response: %v", err)
	}
	for _, field := range []string{"event_id", "event_state"} {
		if _, ok := payload[field]; !ok {
			t.Fatalf("completion response omitted required field %q: %s", field, raw)
		}
	}
}
