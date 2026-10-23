package model

import "sort"

// CanonicalAnomalyOrder is the D3 order. Keep this list as the single Go
// source of truth for validation, replay comparison, and in-memory reads.
var CanonicalAnomalyOrder = []AnomalyCode{
	AnomalyCategoryMismatch,
	AnomalyCountMismatch,
	AnomalyWeightMismatch,
	AnomalyMissingOutcome,
	AnomalyUnallocated,
}

// AnomalyOrderSQL is the MySQL equivalent of CanonicalAnomalyOrder. It is a
// fixed constant, so it is safe to use in GORM Order clauses.
const AnomalyOrderSQL = "FIELD(anomaly_code, 'CATEGORY_MISMATCH', 'COUNT_MISMATCH', 'WEIGHT_MISMATCH', 'MISSING_OUTCOME', 'UNALLOCATED_WEIGHT')"

var anomalyRank = func() map[AnomalyCode]int {
	ranks := make(map[AnomalyCode]int, len(CanonicalAnomalyOrder))
	for rank, code := range CanonicalAnomalyOrder {
		ranks[code] = rank
	}
	return ranks
}()

// SortAnomalyCodes orders a copy of codes by the D3 rank and then by code for
// unknown values. The latter keeps comparisons deterministic while validation
// remains responsible for rejecting unknown codes.
func SortAnomalyCodes(codes []string) []string {
	ordered := append([]string(nil), codes...)
	sort.SliceStable(ordered, func(i, j int) bool {
		left, right := anomalyRankFor(AnomalyCode(ordered[i])), anomalyRankFor(AnomalyCode(ordered[j]))
		if left != right {
			return left < right
		}
		return ordered[i] < ordered[j]
	})
	return ordered
}

func anomalyRankFor(code AnomalyCode) int {
	if rank, ok := anomalyRank[code]; ok {
		return rank
	}
	return len(CanonicalAnomalyOrder)
}
