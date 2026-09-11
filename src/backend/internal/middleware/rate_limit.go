package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"workflow-api/internal/dto"
	"workflow-api/internal/ratelimit"
)

func RateLimit(limiter ratelimit.Limiter) gin.HandlerFunc {
	return func(c *gin.Context) {
		allowed, err := limiter.Allow(c.Request.Context(), c.ClientIP())
		if err != nil {
			c.AbortWithStatusJSON(http.StatusServiceUnavailable, dto.ErrorResponse{
				Code: "AUTH_SERVICE_UNAVAILABLE", Message: "service temporarily unavailable", CorrelationID: GetCorrelationID(c),
			})
			return
		}
		if !allowed {
			c.AbortWithStatusJSON(http.StatusTooManyRequests, dto.ErrorResponse{
				Code: "AUTH_RATE_LIMITED", Message: "too many requests", CorrelationID: GetCorrelationID(c),
			})
			return
		}
		c.Next()
	}
}
