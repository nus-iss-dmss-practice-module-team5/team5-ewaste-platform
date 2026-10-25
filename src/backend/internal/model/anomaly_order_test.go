package model

import "testing"

func TestSortAnomalyCodesUsesD3Order(t *testing.T) {
	got := SortAnomalyCodes([]string{
		string(AnomalyUnallocated),
		string(AnomalyCategoryMismatch),
		string(AnomalyMissingOutcome),
		string(AnomalyWeightMismatch),
		string(AnomalyCountMismatch),
	})
	want := []string{
		string(AnomalyCategoryMismatch),
		string(AnomalyCountMismatch),
		string(AnomalyWeightMismatch),
		string(AnomalyMissingOutcome),
		string(AnomalyUnallocated),
	}
	for index := range want {
		if got[index] != want[index] {
			t.Fatalf("rank %d = %q, want %q", index, got[index], want[index])
		}
	}
}

func TestSortAnomalyCodesDoesNotMutateInput(t *testing.T) {
	input := []string{string(AnomalyUnallocated), string(AnomalyCategoryMismatch)}
	_ = SortAnomalyCodes(input)
	if input[0] != string(AnomalyUnallocated) || input[1] != string(AnomalyCategoryMismatch) {
		t.Fatalf("input was mutated: %v", input)
	}
}

func TestSortAnomalyCodesPlacesUnknownValuesAfterD3Flags(t *testing.T) {
	got := SortAnomalyCodes([]string{"Z_UNKNOWN", string(AnomalyCategoryMismatch)})
	if got[0] != string(AnomalyCategoryMismatch) || got[1] != "Z_UNKNOWN" {
		t.Fatalf("unknown code order = %v", got)
	}
}
