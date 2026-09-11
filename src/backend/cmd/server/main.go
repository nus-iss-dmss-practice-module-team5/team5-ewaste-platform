package main

import (
	"context"
	"crypto/tls"
	"flag"
	"log"
	"os"
	"time"

	"github.com/joho/godotenv"
	"github.com/redis/go-redis/v9"
	"go.uber.org/zap"

	"workflow-api/internal/config"
	"workflow-api/internal/controller"
	"workflow-api/internal/docs"
	"workflow-api/internal/health"
	"workflow-api/internal/logger"
	"workflow-api/internal/ratelimit"
	"workflow-api/internal/repository"
	"workflow-api/internal/router"
	"workflow-api/internal/service"
	"workflow-api/internal/storage"
	"workflow-api/internal/token"
)

func main() {
	if err := godotenv.Load(); err != nil && !os.IsNotExist(err) {
		log.Fatalf("load .env: %v", err)
	}

	modeFlag := flag.String("mode", "", "application mode: development, test, or production")
	checkDependencies := flag.Bool("check-dependencies", false, "connect to MySQL and Redis, then exit")
	flag.Parse()

	cfg, err := config.Load(os.Getenv("EWASTE_CONFIG_FILE"))
	if err != nil {
		log.Fatalf("load config: %v", err)
	}
	if err := cfg.ApplyMode(*modeFlag); err != nil {
		log.Fatalf("apply mode: %v", err)
	}
	if err := cfg.ApplyMode(cfg.Mode); err != nil {
		log.Fatalf("apply configured mode: %v", err)
	}
	appLogger, err := logger.New(cfg.Logging)
	if err != nil {
		log.Fatalf("create logger: %v", err)
	}
	defer func() {
		if err := logger.Close(appLogger); err != nil {
			log.Printf("sync logger: %v", err)
		}
	}()

	if cfg.Database.Host == "" || cfg.Database.Port == 0 || cfg.Database.Name == "" || cfg.Database.User == "" || cfg.Database.Password == "" || (!*checkDependencies && (cfg.Auth.AccessSecret == "" || cfg.Auth.RefreshSecret == "" || cfg.Auth.RefreshHashSecret == "")) {
		appLogger.Fatal("database DSN and all auth secrets must be configured")
	}
	db, err := storage.OpenMySQL(cfg.Database)
	if err != nil {
		appLogger.Error("mysql connection failed", zap.Error(err))
		appLogger.Fatal("connect to mysql")
	}
	if err := storage.PingMySQL(db, 5*time.Second); err != nil {
		appLogger.Error("mysql ping failed", zap.Error(err))
		appLogger.Fatal("ping mysql")
	}

	redisOptions := &redis.Options{Addr: cfg.Redis.Address, Password: cfg.Redis.Password, DB: cfg.Redis.DB}
	if cfg.Redis.TLSEnabled {
		redisOptions.TLSConfig = &tls.Config{MinVersion: tls.VersionTLS12}
	}
	redisClient := redis.NewClient(redisOptions)
	pingCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	err = redisClient.Ping(pingCtx).Err()
	cancel()
	if err != nil {
		appLogger.Error("redis ping failed", zap.Error(err))
		appLogger.Fatal("connect to redis")
	}
	defer func() {
		if err := redisClient.Close(); err != nil {
			appLogger.Warn("close redis client", zap.Error(err))
		}
	}()
	if *checkDependencies {
		appLogger.Info("local dependencies are available", zap.String("mode", cfg.Mode))
		return
	}

	tokens := token.NewService(cfg.Auth.Issuer, cfg.Auth.AccessSecret, cfg.Auth.RefreshSecret, cfg.Auth.RefreshHashSecret, cfg.Auth.AccessTTL, cfg.Auth.RefreshTTL)
	repo := repository.NewGormAuthRepository(db)
	authService := service.NewAuthService(repo, tokens, appLogger)
	authController := controller.NewAuthController(authService, appLogger)
	limiter := ratelimit.NewRedisLimiter(redisClient, cfg.RateLimit.Requests, cfg.RateLimit.Window)
	checker := health.NewChecker(db, redisClient, 3*time.Second)
	appRouter := router.NewAuthRouter(authController, tokens, repo, limiter, checker)
	if cfg.Mode != config.ModeProduction {
		docs.Register(appRouter)
	}

	appLogger.Info("workflow API listening", zap.String("address", cfg.Server.Port))
	if err := appRouter.Run(cfg.Server.Port); err != nil {
		appLogger.Fatal("server stopped")
	}
}
