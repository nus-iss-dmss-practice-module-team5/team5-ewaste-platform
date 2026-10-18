package router

import (
	"github.com/gin-gonic/gin"

	"workflow-api/internal/controller"
	"workflow-api/internal/middleware"
	"workflow-api/internal/repository"
	"workflow-api/internal/token"
)

// RegisterAdmin adds the Administrator routes. They sit behind the same
// access-token check as every other user route; the role check is in the
// service so it runs before any read.
func RegisterAdmin(r *gin.Engine, tokens *token.Service, sessions repository.AuthRepository, platform *controller.PlatformStatusController) {
	if r == nil || platform == nil {
		return
	}
	admin := r.Group("/api/v1/admin")
	admin.Use(middleware.RequireAccessTokens(tokens, sessions))
	admin.GET("/platform-status", platform.GetPlatformStatus)
}
