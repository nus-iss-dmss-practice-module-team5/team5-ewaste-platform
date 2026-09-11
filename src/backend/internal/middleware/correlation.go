package middleware

import (
	"net/http"
	"strings"

	"github.com/gin-gonic/gin"
	"github.com/google/uuid"

	"workflow-api/internal/dto"
)

const CorrelationIDKey = "correlation_id"

func CorrelationID() gin.HandlerFunc {
	return func(c *gin.Context) {
		correlationID := strings.TrimSpace(c.GetHeader("X-Correlation-ID"))
		if len(c.GetHeader("X-Correlation-ID")) > 100 {
			c.Header("X-Correlation-ID", "")
			c.AbortWithStatusJSON(http.StatusBadRequest, dto.ErrorResponse{Code: "AUTH_INVALID_REQUEST", Message: "invalid request", CorrelationID: ""})
			return
		}
		if correlationID == "" {
			correlationID = uuid.NewString()
		}
		c.Set(CorrelationIDKey, correlationID)
		c.Header("X-Correlation-ID", correlationID)
		c.Next()
	}
}

func GetCorrelationID(c *gin.Context) string {
	value, _ := c.Get(CorrelationIDKey)
	correlationID, _ := value.(string)
	return correlationID
}
