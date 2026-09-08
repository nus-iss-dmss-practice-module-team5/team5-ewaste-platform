package logger

import (
	"os"
	"path/filepath"
	"strings"
	"sync"

	"go.uber.org/zap"
	"go.uber.org/zap/zapcore"
	"gopkg.in/natefinch/lumberjack.v2"

	"workflow-api/internal/config"
)

var rotatingSinks sync.Map

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
	rotatingFile := &lumberjack.Logger{
		Filename:   cfg.FilePath,
		MaxSize:    cfg.MaxSizeMB,
		MaxBackups: cfg.MaxBackups,
		MaxAge:     cfg.MaxAgeDays,
		Compress:   cfg.Compress,
	}
	fileSink := zapcore.AddSync(rotatingFile)

	cores := []zapcore.Core{zapcore.NewCore(fileEncoder, fileSink, level)}
	if cfg.Console {
		cores = append(cores, zapcore.NewCore(fileEncoder, zapcore.AddSync(os.Stdout), level))
	}

	log := zap.New(zapcore.NewTee(cores...), zap.AddCaller())
	rotatingSinks.Store(log, rotatingFile)
	return log, nil
}

// Close flushes the logger and closes the rotating file writer.
// zap.Sync alone does not release the file handle on Windows.
func Close(log *zap.Logger) error {
	if log == nil {
		return nil
	}
	syncErr := log.Sync()
	if sink, ok := rotatingSinks.LoadAndDelete(log); ok {
		closeErr := sink.(*lumberjack.Logger).Close()
		if syncErr != nil {
			return syncErr
		}
		return closeErr
	}
	return syncErr
}
