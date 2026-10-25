package controller

import (
	"net/http"

	"github.com/gin-gonic/gin"
	"go.uber.org/zap"

	"workflow-api/internal/apierror"
	"workflow-api/internal/dto"
	"workflow-api/internal/middleware"
	"workflow-api/internal/response"
	"workflow-api/internal/service"
)

type PlatformStatusController struct {
	service *service.PlatformStatusService
	logger  *zap.Logger
}

func NewPlatformStatusController(platform *service.PlatformStatusService, logger *zap.Logger) *PlatformStatusController {
	return &PlatformStatusController{service: platform, logger: logger}
}

// GetPlatformStatus serves the Administrator health and release read. Every
// role other than SYSTEM_ADMIN gets 403 before any source is read.
func (h *PlatformStatusController) GetPlatformStatus(c *gin.Context) {
	claims, ok := middleware.ClaimsFromContext(c)
	if !ok || h.service == nil {
		h.writeError(c, apierror.InvalidSession)
		return
	}
	data, err := h.service.Status(c.Request.Context(), readActor(claims))
	if err != nil {
		h.writeError(c, mapWorkflowReadError(err))
		return
	}
	for source, reason := range data.Unknown {
		if h.logger != nil {
			h.logger.Warn("platform status source unknown", zap.String("source", source), zap.String("reason", reason), zap.String("correlation_id", middleware.GetCorrelationID(c)))
		}
	}
	c.Header("Cache-Control", "no-store")
	response.JSON(c, http.StatusOK, response.Resource[dto.PlatformStatusView]{
		Data: data, CorrelationID: middleware.GetCorrelationID(c),
	})
}

func (h *PlatformStatusController) writeError(c *gin.Context, code apierror.Code) {
	if h.logger != nil {
		h.logger.Warn("platform status request failed", zap.String("error_code", string(code)), zap.String("correlation_id", middleware.GetCorrelationID(c)))
	}
	response.Error(c, code, middleware.GetCorrelationID(c))
}
