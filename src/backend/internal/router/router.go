package router

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"workflow-api/internal/controller"
	"workflow-api/internal/health"
	"workflow-api/internal/middleware"
	"workflow-api/internal/ratelimit"
	"workflow-api/internal/repository"
	"workflow-api/internal/token"
)

func NewAuthRouter(authController *controller.AuthController, tokens *token.Service, repo repository.AuthRepository, limiter ratelimit.Limiter, checker *health.Checker) *gin.Engine {
	gin.SetMode(gin.ReleaseMode)
	r := gin.New()
	r.Use(gin.Recovery(), middleware.CorrelationID())

	r.GET("/healthz", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"status": "ok"})
	})
	r.GET("/readyz", func(c *gin.Context) {
		if checker == nil || checker.Check(c.Request.Context()) != nil {
			c.JSON(http.StatusServiceUnavailable, gin.H{"status": "not_ready"})
			return
		}
		c.JSON(http.StatusOK, gin.H{"status": "ready"})
	})

	r.GET("/api/v1/hello", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"msg": "hello world"})
	})

	auth := r.Group("/api/v1/auth")
	auth.POST("/login", middleware.RateLimit(limiter), authController.Login)
	auth.POST("/refresh", middleware.RateLimit(limiter), authController.Refresh)
	auth.POST("/logout", middleware.RequireAccessTokens(tokens, repo), authController.Logout)

	r.NoRoute(func(c *gin.Context) {
		c.JSON(http.StatusNotFound, gin.H{"msg": "not found"})
	})
	return r
}

func NewTestRouter() *gin.Engine {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.GET("/api/v1/hello", func(c *gin.Context) { c.JSON(http.StatusOK, gin.H{"msg": "hello world"}) })
	r.NoRoute(func(c *gin.Context) { c.JSON(http.StatusNotFound, gin.H{"msg": "not found"}) })
	return r
}
