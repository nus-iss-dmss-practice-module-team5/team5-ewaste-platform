package controller

import (
	"errors"
	"net/http"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"

	"workflow-api/internal/dto"
	"workflow-api/internal/middleware"
	"workflow-api/internal/service"
)

type AuthController struct {
	service *service.AuthService
	logger  *zap.Logger
}

func NewAuthController(authService *service.AuthService, logger *zap.Logger) *AuthController {
	return &AuthController{service: authService, logger: logger}
}

func (h *AuthController) Login(c *gin.Context) {
	var request dto.LoginRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		h.error(c, http.StatusBadRequest, "AUTH_INVALID_REQUEST", "invalid request", err)
		return
	}
	response, err := h.service.Login(c.Request.Context(), request)
	if err != nil {
		if errors.Is(err, service.ErrInvalidCredentials) {
			h.error(c, http.StatusUnauthorized, "AUTH_INVALID_CREDENTIALS", "invalid credentials", nil)
			return
		}
		h.error(c, http.StatusServiceUnavailable, "AUTH_SERVICE_UNAVAILABLE", "service temporarily unavailable", err)
		return
	}
	c.JSON(http.StatusOK, response)
}

func (h *AuthController) Refresh(c *gin.Context) {
	var request dto.RefreshRequest
	if err := c.ShouldBindJSON(&request); err != nil {
		h.error(c, http.StatusBadRequest, "AUTH_INVALID_REQUEST", "invalid request", err)
		return
	}
	response, err := h.service.Refresh(c.Request.Context(), request.RefreshToken)
	if err != nil {
		if errors.Is(err, service.ErrInvalidSession) {
			h.error(c, http.StatusUnauthorized, "AUTH_INVALID_SESSION", "invalid or expired session", nil)
			return
		}
		h.error(c, http.StatusServiceUnavailable, "AUTH_SERVICE_UNAVAILABLE", "service temporarily unavailable", err)
		return
	}
	c.JSON(http.StatusOK, response)
}

func (h *AuthController) Logout(c *gin.Context) {
	claims, ok := middleware.ClaimsFromContext(c)
	if !ok {
		h.error(c, http.StatusUnauthorized, "AUTH_INVALID_SESSION", "invalid or expired session", nil)
		return
	}
	if err := h.service.Logout(c.Request.Context(), claims.UserID, claims.SessionID); err != nil {
		if errors.Is(err, service.ErrInvalidSession) {
			h.error(c, http.StatusUnauthorized, "AUTH_INVALID_SESSION", "invalid or expired session", nil)
			return
		}
		h.error(c, http.StatusServiceUnavailable, "AUTH_SERVICE_UNAVAILABLE", "service temporarily unavailable", err)
		return
	}
	c.Status(http.StatusNoContent)
}

func (h *AuthController) error(c *gin.Context, status int, code, message string, err error) {
	if err != nil {
		// Do not log the underlying error: database and dependency errors may contain SQL or sensitive details.
		h.logger.Warn("authentication request failed", zap.String("code", code))
	}
	c.JSON(status, dto.ErrorResponse{Code: code, Message: message, CorrelationID: middleware.GetCorrelationID(c)})
}
