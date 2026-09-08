package logger

import (
	"os"
	"path/filepath"
	"strings"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"gopkg.in/natefinch/lumberjack.v2"

	"workflow-api/internal/config"
)

func New(cfg config.LoggingConfig) (*zap.Logger, error) {
	if err := os.MkdirAll(filepath.Dir(cfg.FilePath), 0o755); err != nil {
		return nil, err
	}

	level := zapcore.InfoLevel
	if err := level.UnmarshalText([]byte(strings.ToLower(cfg.Level))); err != nil {
		return nil, err
	}

	encoderConfig := zap.NewProductionEncoderConfig()
	encoderConfig.TimeKey = "timestamp"
	encoderConfig.EncodeTime = zapcore.ISO8601TimeEncoder
	fileEncoder := zapcore.NewJSONEncoder(encoderConfig)
	fileSink := zapcore.AddSync(&lumberjack.Logger{
		Filename:   cfg.FilePath,
		MaxSize:    cfg.MaxSizeMB,
		MaxBackups: cfg.MaxBackups,
		MaxAge:     cfg.MaxAgeDays,
		Compress:   cfg.Compress,
	})

	cores := []zapcore.Core{zapcore.NewCore(fileEncoder, fileSink, level)}
	if cfg.Console {
		cores = append(cores, zapcore.NewCore(fileEncoder, zapcore.AddSync(os.Stdout), level))
	}

	return zap.New(zapcore.NewTee(cores...), zap.AddCaller()), nil
}
