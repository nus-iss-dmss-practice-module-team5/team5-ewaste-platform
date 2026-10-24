package service

import "errors"

var (
	ErrAssignmentForbidden           = errors.New("assignment: forbidden")
	ErrAssignmentNotFound            = errors.New("assignment: not found")
	ErrAssignmentInvalidState        = errors.New("assignment: invalid state")
	ErrAssignmentStaleVersion        = errors.New("assignment: stale version")
	ErrAssignmentValidation          = errors.New("assignment: validation failed")
	ErrAssignmentIdempotencyConflict = errors.New("assignment: idempotency conflict")
	ErrAssignmentInProgress          = errors.New("assignment: command already in progress")
	ErrAssignmentConcurrent          = errors.New("assignment: concurrent update")
)
