package middleware

import (
	"errors"
	"net/http"
	"strings"
	"time"

	"github.com/gin-gonic/gin"

	"workflow-api/internal/dto"
	"workflow-api/internal/repository"
	"workflow-api/internal/token"
)

const ClaimsKey = "claims"

func RequireAccessTokens(tokens *token.Service, sessions repository.AuthRepository) gin.HandlerFunc {
	return func(c *gin.Context) {
		parts := strings.Fields(c.GetHeader("Authorization"))
		if len(parts) != 2 || !strings.EqualFold(parts[0], "Bearer") {
			abortAuth(c)
			return
		}
		claims, err := tokens.ParseAccess(parts[1])
		if err != nil {
			abortAuth(c)
			return
		}
		session, err := sessions.FindSession(c.Request.Context(), claims.SessionID)
		if errors.Is(err, repository.ErrNotFound) || (err == nil && (session == nil || session.UserID != claims.UserID || !session.IsActive(now()))) {
			abortAuth(c)
			return
		}
		if err != nil {
			abortDependency(c)
			return
		}
		user, err := sessions.FindActiveUserByID(c.Request.Context(), claims.UserID)
		if errors.Is(err, repository.ErrNotFound) || (err == nil && user.UserID != claims.UserID) {
			abortAuth(c)
			return
		}
		if err != nil {
			abortDependency(c)
			return
		}
		c.Set(ClaimsKey, claims)
		c.Next()
	}
}

func ClaimsFromContext(c *gin.Context) (*token.Claims, bool) {
	value, exists := c.Get(ClaimsKey)
	if !exists {
		return nil, false
	}
	claims, ok := value.(*token.Claims)
	return claims, ok
}

func abortAuth(c *gin.Context) {
	c.AbortWithStatusJSON(http.StatusUnauthorized, dto.ErrorResponse{
		Code: "AUTH_INVALID_SESSION", Message: "invalid or expired session", CorrelationID: GetCorrelationID(c),
	})
}

func abortDependency(c *gin.Context) {
	c.AbortWithStatusJSON(http.StatusServiceUnavailable, dto.ErrorResponse{
		Code: "AUTH_SERVICE_UNAVAILABLE", Message: "service temporarily unavailable", CorrelationID: GetCorrelationID(c),
	})
}

var now = func() time.Time { return time.Now().UTC() }
