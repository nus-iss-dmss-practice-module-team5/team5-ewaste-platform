package middleware

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

const allowedUIOrigin = "https://aca-ewaste-dev-ui.kindflower-300f4866.malaysiawest.azurecontainerapps.io"

// CORS allows the deployed UI to call the API from a browser.
// Keep the allow-list explicit so other origins cannot use the API through CORS.
func CORS() gin.HandlerFunc {
	return func(c *gin.Context) {
		if c.GetHeader("Origin") != allowedUIOrigin {
			c.Next()
			return
		}

		c.Header("Access-Control-Allow-Origin", allowedUIOrigin)
		c.Header("Access-Control-Allow-Methods", "GET, POST, OPTIONS")
		c.Header("Access-Control-Allow-Headers", "Authorization, Content-Type, X-Correlation-ID")
		c.Header("Access-Control-Max-Age", "600")
		c.Header("Vary", "Origin")

		if c.Request.Method == http.MethodOptions {
			c.AbortWithStatus(http.StatusNoContent)
			return
		}

		c.Next()
	}
}
