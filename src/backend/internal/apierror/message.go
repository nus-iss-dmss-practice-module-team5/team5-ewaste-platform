package apierror

var Messages = map[Code]string{
	InvalidRequest:     "invalid request",
	InvalidCredentials: "invalid credentials",
	InvalidSession:     "invalid or expired session",
	Forbidden:          "access denied",
	NotFound:           "resource not found",
	StaleVersion:       "The resource has changed. Refresh and retry.",
	ValidationError:    "one or more fields are invalid",
	RateLimited:        "too many requests",
	ServiceUnavailable: "service temporarily unavailable",
}
