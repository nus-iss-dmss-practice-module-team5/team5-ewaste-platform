package health

import (
	"context"
	"errors"
	"time"

	"github.com/redis/go-redis/v9"
	"gorm.io/gorm"
)

type Checker struct {
	mysqlPing func(context.Context) error
	redisPing func(context.Context) error
	timeout   time.Duration
}

func NewChecker(db *gorm.DB, redisClient *redis.Client, timeout time.Duration) *Checker {
	return NewCheckerWithPingers(
		func(ctx context.Context) error {
			sqlDB, err := db.DB()
			if err != nil {
				return err
			}
			return sqlDB.PingContext(ctx)
		},
		func(ctx context.Context) error { return redisClient.Ping(ctx).Err() },
		timeout,
	)
}

func NewCheckerWithPingers(mysqlPing, redisPing func(context.Context) error, timeout time.Duration) *Checker {
	return &Checker{mysqlPing: mysqlPing, redisPing: redisPing, timeout: timeout}
}

func (c *Checker) Check(ctx context.Context) error {
	if c == nil || c.mysqlPing == nil || c.redisPing == nil {
		return errors.New("health checker is not configured")
	}
	checkCtx, cancel := context.WithTimeout(ctx, c.timeout)
	defer cancel()
	if err := c.mysqlPing(checkCtx); err != nil {
		return err
	}
	return c.redisPing(checkCtx)
}
