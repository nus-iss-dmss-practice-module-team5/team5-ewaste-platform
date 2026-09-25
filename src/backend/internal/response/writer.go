package response

import (
	"net/http"

	"github.com/gin-gonic/gin"

	"workflow-api/internal/apierror"
	"workflow-api/internal/dto"
)

func JSON(c *gin.Context, status int, body any) {
	c.JSON(status, body)
}

func Error(c *gin.Context, code apierror.Code, correlationID string) {
	c.AbortWithStatusJSON(apierror.Status(code), dto.ErrorResponse{
		Code:          string(code),
		Message:       apierror.Messages[code],
		CorrelationID: correlationID,
	})
}

func NoContent(c *gin.Context) {
	c.Status(http.StatusNoContent)
}
