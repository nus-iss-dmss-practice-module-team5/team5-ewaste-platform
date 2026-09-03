package main

import (
	"net/http"

	"github.com/gin-gonic/gin"
)

func main() {
	if err := newTestRouter().Run(":8080"); err != nil {
		panic(err.Error())
	}
}

func newTestRouter() *gin.Engine {

	gin.SetMode(gin.TestMode)

	r := gin.Default()

	r.GET("/api/v1/hello", func(c *gin.Context) {
		c.JSON(http.StatusOK, gin.H{"msg": "hello world"})
	})

	r.NoRoute(func(c *gin.Context) {
		c.JSON(http.StatusNotFound, gin.H{"msg": "not found"})
	})

	return r
}
