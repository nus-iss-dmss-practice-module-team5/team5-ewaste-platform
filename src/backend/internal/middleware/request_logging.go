package middleware

import (
	"time"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"
)

func RequestLogger(log *zap.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		startedAt := time.Now()

		c.Next()

		if log == nil {
			return
		}

		duration := time.Since(startedAt)
		log.Info(
			"http request",
			zap.String("component", "workflow-api"),
			zap.String("method", c.Request.Method),
			zap.String("path", c.Request.URL.Path),
			zap.Int("status", c.Writer.Status()),
			zap.Duration("duration", duration),
			zap.Int64("latency_ms", duration.Milliseconds()),
			zap.String("correlation_id", GetCorrelationID(c)),
		)
	}
}
