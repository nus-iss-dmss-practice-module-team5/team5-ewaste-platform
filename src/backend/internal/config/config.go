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
	Kafka     KafkaConfig     `mapstructure:"kafka"`
	Auth      AuthConfig      `mapstructure:"auth"`
	RateLimit RateLimitConfig `mapstructure:"rate_limit"`
	Logging   LoggingConfig   `mapstructure:"logging"`
}

const (
	ModeDevelopment = "development"
	ModeTest        = "test"
	ModeProduction  = "production"
)

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
		if c.Database.Host == "" {
			c.Database.Host = "localhost"
		}
		if c.Database.Port == 0 {
			c.Database.Port = 3307
		}
		if c.Redis.Address == "" {
			c.Redis.Address = "localhost:6379"
		}
	}
	return nil
}

type KafkaConfig struct {
	Enabled             bool          `mapstructure:"enabled"`
	Brokers             []string      `mapstructure:"brokers"`
	ClientID            string        `mapstructure:"client_id"`
	PublishInterval     time.Duration `mapstructure:"publish_interval"`
	BatchSize           int           `mapstructure:"batch_size"`
	MaxAttempts         int           `mapstructure:"max_attempts"`
	LeaseDuration       time.Duration `mapstructure:"lease_duration"`
	LeaderLeaseDuration time.Duration `mapstructure:"leader_lease_duration"`
	RetryBackoff        time.Duration `mapstructure:"retry_backoff"`
	PublishTimeout      time.Duration `mapstructure:"publish_timeout"`
}

type ServerConfig struct {
	Port           string   `mapstructure:"port"`
	AllowedOrigins []string `mapstructure:"allowed_origins"`
}

type DatabaseConfig struct {
	Host     string `mapstructure:"host"`
	Port     int    `mapstructure:"port"`
	Name     string `mapstructure:"name"`
	User     string `mapstructure:"user"`
	Password string `mapstructure:"password"`
}

type RedisConfig struct {
	Address    string `mapstructure:"address"`
	Password   string `mapstructure:"password"`
	DB         int    `mapstructure:"db"`
	TLSEnabled bool   `mapstructure:"tls_enabled"`
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
	decodeHook := mapstructure.ComposeDecodeHookFunc(
		mapstructure.StringToTimeDurationHookFunc(),
		mapstructure.StringToSliceHookFunc(","),
	)
	if err := v.Unmarshal(&cfg, viper.DecodeHook(decodeHook)); err != nil {
		return Config{}, err
	}
	return cfg, nil
}

func setDefaults(v *viper.Viper) {
	v.SetDefault("mode", ModeDevelopment)
	v.SetDefault("server.port", ":8080")
	v.SetDefault("server.allowed_origins", []string{"http://localhost:3000"})
	v.SetDefault("database.host", "localhost")
	v.SetDefault("database.port", 3306)
	v.SetDefault("database.name", "ewaste")
	v.SetDefault("database.user", "ewaste_app")
	v.SetDefault("database.password", "")
	v.SetDefault("redis.address", "localhost:6379")
	v.SetDefault("redis.password", "")
	v.SetDefault("redis.db", 0)
	v.SetDefault("redis.tls_enabled", false)
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
	v.SetDefault("kafka.enabled", false)
	v.SetDefault("kafka.brokers", []string{"localhost:9092"})
	v.SetDefault("kafka.client_id", "workflow-api")
	v.SetDefault("kafka.publish_interval", time.Second)
	v.SetDefault("kafka.batch_size", 50)
	v.SetDefault("kafka.max_attempts", 5)
	v.SetDefault("kafka.lease_duration", 30*time.Second)
	v.SetDefault("kafka.leader_lease_duration", 30*time.Second)
	v.SetDefault("kafka.retry_backoff", 5*time.Second)
	v.SetDefault("kafka.publish_timeout", 10*time.Second)
}

func bindEnvironment(v *viper.Viper) {
	keys := []string{
		"mode",
		"server.port",
		"server.allowed_origins",
		"database.host",
		"database.port",
		"database.name",
		"database.user",
		"database.password",
		"redis.address",
		"redis.password",
		"redis.db",
		"redis.tls_enabled",
		"auth.issuer",
		"auth.access_secret",
		"auth.refresh_secret",
		"auth.access_ttl",
		"auth.refresh_ttl",
		"auth.refresh_hash_secret",
		"rate_limit.requests",
		"rate_limit.window",
		"logging.level",
		"logging.file_path",
		"logging.max_size_mb",
		"logging.max_backups",
		"logging.max_age_days",
		"logging.compress",
		"logging.console",
		"kafka.enabled",
		"kafka.brokers",
		"kafka.client_id",
		"kafka.publish_interval",
		"kafka.batch_size",
		"kafka.max_attempts",
		"kafka.lease_duration",
		"kafka.leader_lease_duration",
		"kafka.retry_backoff",
		"kafka.publish_timeout",
	}
	for _, key := range keys {
		envName := "EWASTE_" + strings.ToUpper(strings.ReplaceAll(key, ".", "_"))
		if key == "database.password" {
			_ = v.BindEnv(key, "MYSQL_PASSWORD", envName)
			continue
		}
		if key == "redis.password" {
			_ = v.BindEnv(key, "REDIS_PASSWORD", envName)
			continue
		}
		_ = v.BindEnv(key, envName)
	}
}
