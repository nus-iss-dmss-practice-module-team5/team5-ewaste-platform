package storage

import (
	"context"
	"time"

	"gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"

	"workflow-api/internal/config"
)

func OpenMySQL(cfg config.DatabaseConfig) (*gorm.DB, error) {
	return gorm.Open(mysql.Open(cfg.DSN), &gorm.Config{Logger: logger.Default.LogMode(logger.Silent)})
}

func PingMySQL(db *gorm.DB, timeout time.Duration) error {
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	sqlDB, err := db.DB()
	if err != nil {
		return err
	}
	return sqlDB.PingContext(ctx)
}
