package apierror

var Message = map[Code]string{
	InvalidRequest:     "invalid request",
	InvalidCredentials: "invalid credentials",
	InvalidSession:     "invalid or expired session",
	Forbidden:          "access denied",
	NotFound:           "resource not found",
	StaleVersion:       "the resource has changed, refresh and retry",
	ValidationError:    "one or more fields are invalid",
	RateLimited:        "too many requests",
	ServiceUnavailable: "service temporarily unavailable",
}
