package response

type Resource[T any] struct {
	Data          T      `json:"data"`
	CorrelationID string `json:"correlation_id"`
}

type Mutation[T any] struct {
	Data          T      `json:"data"`
	CorrelationID string `json:"correlation_id"`
	EventID       string `json:"event_id,omitempty"`
	EventState    string `json:"event_state,omitempty"`
}

type Page[T any] struct {
	Data          []T    `json:"data"`
	Page          int    `json:"page"`
	PageSize      int    `json:"page_size"`
	TotalCount    int64  `json:"total_count"`
	CorrelationID string `json:"correlation_id"`
}
