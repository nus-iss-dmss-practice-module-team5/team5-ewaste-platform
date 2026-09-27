package outbox

import (
	"context"
	"errors"
	"time"

	"go.uber.org/zap"

	"workflow-api/internal/model"
	"workflow-api/internal/repository"
)

const KafkaPublishErrorCode = "KAFKA_PUBLISH_FAILED"

type Publisher interface {
	Publish(context.Context, model.EventOutbox) error
	Close() error
}

type RelayConfig struct {
	PollInterval        time.Duration
	BatchSize           int
	MaxAttempts         int
	LeaseDuration       time.Duration
	LeaderLeaseDuration time.Duration
	RetryBackoff        time.Duration
	PublishTimeout      time.Duration
}

type Relay struct {
	repository         repository.OutboxRepository
	publisher          Publisher
	leaderLeaseFactory LeaderLeaseFactory
	config             RelayConfig
	logger             *zap.Logger
	now                func() time.Time
}

func NewRelay(
	repo repository.OutboxRepository,
	publisher Publisher,
	leaderLeaseFactory LeaderLeaseFactory,
	cfg RelayConfig,
	logger *zap.Logger,
) *Relay {
	if cfg.PollInterval <= 0 {
		cfg.PollInterval = time.Second
	}
	if cfg.BatchSize <= 0 {
		cfg.BatchSize = 50
	}
	if cfg.MaxAttempts <= 0 {
		cfg.MaxAttempts = 5
	}
	if cfg.LeaseDuration <= 0 {
		cfg.LeaseDuration = 30 * time.Second
	}
	if cfg.LeaderLeaseDuration <= 0 {
		cfg.LeaderLeaseDuration = 30 * time.Second
	}
	if cfg.RetryBackoff <= 0 {
		cfg.RetryBackoff = 5 * time.Second
	}
	if cfg.PublishTimeout <= 0 {
		cfg.PublishTimeout = 10 * time.Second
	}
	if logger == nil {
		logger = zap.NewNop()
	}

	return &Relay{
		repository:         repo,
		publisher:          publisher,
		leaderLeaseFactory: leaderLeaseFactory,
		config:             cfg,
		logger:             logger,
		now:                func() time.Time { return time.Now().UTC() },
	}
}

// Run keeps one fenced relay active across application replicas. Redis is
// used only for control-plane ownership; event data remains in MySQL and the
// business payload is delivered through Kafka.
func (r *Relay) Run(ctx context.Context) {
	for {
		if ctx.Err() != nil {
			return
		}

		lease, acquired, err := r.leaderLeaseFactory.Acquire(
			ctx,
			r.config.LeaderLeaseDuration,
		)
		if err != nil {
			r.logger.Error("acquire outbox relay lease", zap.Error(err))
			r.wait(ctx, r.config.PollInterval)
			continue
		}
		if !acquired {
			r.wait(ctx, r.config.PollInterval)
			continue
		}

		r.runAsLeader(ctx, lease)
	}
}

// Heartbeats run independently of broker calls. Losing leadership cancels all
// in-flight work; publication remains at-least-once and consumers deduplicate IDs.
func (r *Relay) runAsLeader(ctx context.Context, lease LeaderLease) {
	leasedContext, cancel := context.WithCancel(ctx)
	renewed := make(chan struct{})
	interval := r.config.LeaderLeaseDuration / 3
	if interval <= 0 {
		interval = time.Second
	}
	go func() {
		defer close(renewed)
		ticker := time.NewTicker(interval)
		defer ticker.Stop()
		for {
			select {
			case <-leasedContext.Done():
				return
			case <-ticker.C:
				renewContext, stopRenew := context.WithTimeout(leasedContext, interval)
				err := lease.Renew(renewContext, r.config.LeaderLeaseDuration)
				stopRenew()
				if err != nil {
					r.logger.Error("outbox leadership lost", zap.Error(err))
					cancel()
					return
				}
			}
		}
	}()
	defer func() {
		cancel()
		<-renewed
		releaseContext, stopRelease := context.WithTimeout(context.Background(), time.Second)
		defer stopRelease()
		if err := lease.Release(releaseContext); err != nil {
			r.logger.Warn("release outbox relay lease", zap.Error(err))
		}
	}()
	for leasedContext.Err() == nil {
		r.processOnce(leasedContext)
		r.wait(leasedContext, r.config.PollInterval)
	}
}

func (r *Relay) processOnce(ctx context.Context) {
	if ctx.Err() != nil {
		return
	}

	events, err := r.repository.ClaimPending(
		ctx,
		r.now(),
		r.config.BatchSize,
		r.config.LeaseDuration,
	)
	if err != nil {
		r.logger.Error("claim pending outbox events", zap.Error(err))
		return
	}

	for _, event := range events {
		if ctx.Err() != nil {
			return
		}

		publishContext, cancel := context.WithTimeout(
			ctx,
			r.config.PublishTimeout,
		)
		publishErr := r.publisher.Publish(publishContext, event)
		cancel()
		if ctx.Err() != nil {
			return
		}

		if publishErr != nil {
			var permanentError interface{ Permanent() bool }
			if errors.As(publishErr, &permanentError) && permanentError.Permanent() {
				if quarantineErr := r.repository.MarkQuarantined(
					ctx,
					event.EventID,
					"OUTBOX_EVENT_INVALID",
				); quarantineErr != nil {
					r.logger.Error(
						"quarantine outbox event",
						zap.String("event_id", event.EventID),
						zap.Error(quarantineErr),
					)
				}
				continue
			}

			// Transient broker outages remain PENDING and recover automatically.
			// MaxAttempts bounds each Kafka send, not the lifetime of durable intent.

			if retryErr := r.repository.MarkRetry(
				ctx,
				event.EventID,
				r.now().Add(r.config.RetryBackoff),
				KafkaPublishErrorCode,
			); retryErr != nil {
				r.logger.Error(
					"reschedule outbox event",
					zap.String("event_id", event.EventID),
					zap.Error(retryErr),
				)
			}

			r.logger.Warn(
				"publish outbox event failed",
				zap.String("event_id", event.EventID),
				zap.String("event_type", event.EventType),
				zap.Error(publishErr),
			)
			continue
		}

		if markErr := r.repository.MarkPublished(
			ctx,
			event.EventID,
			r.now(),
		); markErr != nil {
			r.logger.Error(
				"mark outbox event published",
				zap.String("event_id", event.EventID),
				zap.Error(markErr),
			)
		}
	}
}

func (r *Relay) wait(ctx context.Context, duration time.Duration) {
	timer := time.NewTimer(duration)
	defer timer.Stop()

	select {
	case <-ctx.Done():
	case <-timer.C:
	}
}
