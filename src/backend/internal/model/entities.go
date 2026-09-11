package model

import "time"

type Organisation struct {
	OrganisationID   string    `gorm:"column:organisation_id;primaryKey;size:32"`
	OrganisationName string    `gorm:"column:organisation_name;uniqueIndex;size:160"`
	OrganisationType string    `gorm:"column:organisation_type;size:40"`
	Status           string    `gorm:"column:status;size:24"`
	CreatedAt        time.Time `gorm:"column:created_at"`
	UpdatedAt        time.Time `gorm:"column:updated_at"`
}

func (Organisation) TableName() string { return "organisations" }

type Role struct {
	RoleCode                string    `gorm:"column:role_code;primaryKey;size:32"`
	DisplayName             string    `gorm:"column:display_name;uniqueIndex;size:80"`
	Description             string    `gorm:"column:description;size:255"`
	AllowedOrganisationType string    `gorm:"column:allowed_organisation_type;size:40"`
	IsActive                bool      `gorm:"column:is_active"`
	CreatedAt               time.Time `gorm:"column:created_at"`
}

func (Role) TableName() string { return "roles" }

type User struct {
	UserID              string     `gorm:"column:user_id;primaryKey;size:32"`
	Email               string     `gorm:"column:email;uniqueIndex;size:254"`
	DisplayName         string     `gorm:"column:display_name;size:120"`
	PasswordHash        string     `gorm:"column:password_hash;size:255"`
	RoleCode            string     `gorm:"column:role_code;size:32"`
	OrganisationID      string     `gorm:"column:organisation_id;size:32"`
	Status              string     `gorm:"column:status;size:24"`
	FailedLoginAttempts uint16     `gorm:"column:failed_login_attempts"`
	LockedUntil         *time.Time `gorm:"column:locked_until"`
	LastLoginAt         *time.Time `gorm:"column:last_login_at"`
	CreatedAt           time.Time  `gorm:"column:created_at"`
	UpdatedAt           time.Time  `gorm:"column:updated_at"`
}

func (User) TableName() string { return "users" }

type Session struct {
	SessionID        string `gorm:"column:session_id;primaryKey;size:36"`
	UserID           string `gorm:"column:user_id;size:32"`
	RefreshTokenHash string `gorm:"column:token_hash;size:64"`
	// Status is retained for in-memory test doubles. Session state in MySQL is
	// represented by revoked_at, so this field must not be persisted.
	Status           string     `gorm:"-"`
	IssuedAt         time.Time  `gorm:"column:issued_at"`
	ExpiresAt        time.Time  `gorm:"column:expires_at"`
	LastSeenAt       *time.Time `gorm:"column:last_seen_at"`
	RevokedAt        *time.Time `gorm:"column:revoked_at"`
	RevocationReason *string    `gorm:"column:revocation_reason;size:120"`
}

func (Session) TableName() string { return "sessions" }

// IsActive reports whether a session is usable at the supplied time.
// Persisted sessions use revoked_at; Status supports existing in-memory callers.
func (s *Session) IsActive(now time.Time) bool {
	return s != nil && s.ExpiresAt.After(now) && s.RevokedAt == nil && (s.Status == "" || s.Status == "ACTIVE")
}
