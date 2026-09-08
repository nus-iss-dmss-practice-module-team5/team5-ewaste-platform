package config

import (
	"errors"
	"strings"
	"time"

	"github.com/mitchellh/mapstructure"
	"github.com/spf13/viper"
)

type Config struct {
	Mode      string          `mapstructure:"mode"`
	Server    ServerConfig    `mapstructure:"server"`
	Database  DatabaseConfig  `mapstructure:"database"`
	Redis     RedisConfig     `mapstructure:"redis"`
	Auth      AuthConfig      `mapstructure:"auth"`
	RateLimit RateLimitConfig `mapstructure:"rate_limit"`
	Logging   LoggingConfig   `mapstructure:"logging"`
}

const (
	ModeDevelopment = "development"
	ModeTest        = "test"
	ModeProduction  = "production"
)

const testMySQLDSN = "ewaste_app:ewaste-local-only@tcp(localhost:3307)/ewaste?charset=utf8mb4&parseTime=True&loc=UTC"

// ApplyMode applies only safe mode defaults. Explicit config-file and environment values win.
func (c *Config) ApplyMode(mode string) error {
	mode = strings.ToLower(strings.TrimSpace(mode))
	if mode == "" {
		return nil
	}
	switch mode {
	case ModeDevelopment, ModeTest, ModeProduction:
		c.Mode = mode
	default:
		return errors.New("unsupported application mode")
	}
	if mode == ModeTest {
		if c.Database.DSN == "" {
			c.Database.DSN = testMySQLDSN
		}
		if c.Redis.Address == "" {
			c.Redis.Address = "localhost:6379"
		}
	}
	return nil
}

type ServerConfig struct {
	Port string `mapstructure:"port"`
}

type DatabaseConfig struct {
	DSN string `mapstructure:"dsn"`
}

type RedisConfig struct {
	Address  string `mapstructure:"address"`
	Password string `mapstructure:"password"`
	DB       int    `mapstructure:"db"`
}

type AuthConfig struct {
	Issuer            string        `mapstructure:"issuer"`
	AccessSecret      string        `mapstructure:"access_secret"`
	RefreshSecret     string        `mapstructure:"refresh_secret"`
	AccessTTL         time.Duration `mapstructure:"access_ttl"`
	RefreshTTL        time.Duration `mapstructure:"refresh_ttl"`
	RefreshHashSecret string        `mapstructure:"refresh_hash_secret"`
}

type RateLimitConfig struct {
	Requests int           `mapstructure:"requests"`
	Window   time.Duration `mapstructure:"window"`
}

type LoggingConfig struct {
	Level      string `mapstructure:"level"`
	FilePath   string `mapstructure:"file_path"`
	MaxSizeMB  int    `mapstructure:"max_size_mb"`
	MaxBackups int    `mapstructure:"max_backups"`
	MaxAgeDays int    `mapstructure:"max_age_days"`
	Compress   bool   `mapstructure:"compress"`
	Console    bool   `mapstructure:"console"`
}

func Load(configFile string) (Config, error) {
	v := viper.New()
	v.SetConfigName("config")
	v.SetConfigType("yaml")
	v.AddConfigPath(".")
	v.AddConfigPath("./config")
	if configFile != "" {
		v.SetConfigFile(configFile)
	}

	v.SetEnvPrefix("EWASTE")
	v.SetEnvKeyReplacer(strings.NewReplacer(".", "_"))
	v.AutomaticEnv()

	setDefaults(v)
	bindEnvironment(v)

	if err := v.ReadInConfig(); err != nil {
		if _, ok := errors.AsType[viper.ConfigFileNotFoundError](err); !ok {
			return Config{}, err
		}
	}

	var cfg Config
	if err := v.Unmarshal(&cfg, viper.DecodeHook(mapstructure.ComposeDecodeHookFunc(
		mapstructure.StringToTimeDurationHookFunc(),
	))); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func setDefaults(v *viper.Viper) {
	v.SetDefault("mode", ModeDevelopment)
	v.SetDefault("server.port", ":8080")
	v.SetDefault("database.dsn", "")
	v.SetDefault("redis.address", "localhost:6379")
	v.SetDefault("redis.password", "")
	v.SetDefault("redis.db", 0)
	v.SetDefault("auth.issuer", "ewaste-workflow-api")
	v.SetDefault("auth.access_ttl", 15*time.Minute)
	v.SetDefault("auth.refresh_ttl", 24*time.Hour)
	v.SetDefault("auth.access_secret", "")
	v.SetDefault("auth.refresh_secret", "")
	v.SetDefault("auth.refresh_hash_secret", "")
	v.SetDefault("rate_limit.requests", 10)
	v.SetDefault("rate_limit.window", time.Minute)
	v.SetDefault("logging.level", "info")
	v.SetDefault("logging.file_path", "logs/workflow-api.log")
	v.SetDefault("logging.max_size_mb", 10)
	v.SetDefault("logging.max_backups", 5)
	v.SetDefault("logging.max_age_days", 30)
	v.SetDefault("logging.compress", true)
	v.SetDefault("logging.console", true)
}

func bindEnvironment(v *viper.Viper) {
	keys := []string{
		"mode",
		"server.port", "database.dsn", "redis.address", "redis.password", "redis.db",
		"auth.issuer", "auth.access_secret", "auth.refresh_secret", "auth.refresh_hash_secret",
		"auth.access_ttl", "auth.refresh_ttl", "rate_limit.requests", "rate_limit.window",
		"logging.level", "logging.file_path", "logging.max_size_mb", "logging.max_backups",
		"logging.max_age_days", "logging.compress", "logging.console",
	}
	for _, key := range keys {
		_ = v.BindEnv(key)
	}
}
