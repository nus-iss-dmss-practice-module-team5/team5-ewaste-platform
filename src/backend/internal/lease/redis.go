package lease

import (
	"context"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/google/uuid"
	"github.com/redis/go-redis/v9"
)

var (
	ErrBusy        = errors.New("lease: busy")
	ErrUnavailable = errors.New("lease: unavailable")
	ErrLost        = errors.New("lease: lost")
)

type Handle interface {
	Release(ctx context.Context) error
}

// RenewableHandle is implemented by leases that can extend ownership while
// the protected database transaction is still running. Batch claim work can
// legitimately exceed the short acquisition TTL during lock contention.
type RenewableHandle interface {
	Handle
	Renew(ctx context.Context) error
	RenewInterval() time.Duration
}

type BatchLease interface {
	Acquire(ctx context.Context, batchID string) (Handle, error)
}

type RedisBatchLease struct {
	client         *redis.Client
	prefix         string
	ttl            time.Duration
	acquireTimeout time.Duration
	releaseScript  *redis.Script
	renewScript    *redis.Script
}

func NewRedisBatchLease(
	client *redis.Client,
	ttl time.Duration,
	acquireTimeout time.Duration,
) *RedisBatchLease {
	return &RedisBatchLease{
		client:         client,
		prefix:         "ewaste:claim:lock:",
		ttl:            ttl,
		acquireTimeout: acquireTimeout,
		releaseScript: redis.NewScript(`
if redis.call('GET', KEYS[1]) == ARGV[1] then
	return redis.call('DEL', KEYS[1])
end
return 0
`),
		renewScript: redis.NewScript(`
if redis.call('GET', KEYS[1]) == ARGV[1] then
	return redis.call('PEXPIRE', KEYS[1], ARGV[2])
end
return 0
`),
	}
}

func (l *RedisBatchLease) Acquire(
	ctx context.Context,
	batchID string,
) (Handle, error) {
	if l.client == nil || l.ttl <= 0 || l.acquireTimeout <= 0 {
		return nil, ErrUnavailable
	}

	acquireCtx, cancel := context.WithTimeout(ctx, l.acquireTimeout)
	defer cancel()

	token := uuid.NewString()
	key := l.prefix + batchID

	err := l.client.SetArgs(
		acquireCtx,
		key,
		token,
		redis.SetArgs{
			Mode: "NX",
			TTL:  l.ttl,
		},
	).Err()

	if errors.Is(err, redis.Nil) {
		return nil, ErrBusy
	}
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrUnavailable, err)
	}

	return &redisLeaseHandle{
		client: l.client,
		key:    key,
		token:  token,
		ttl:    l.ttl,
		script: l.releaseScript,
		renew:  l.renewScript,
	}, nil
}

type redisLeaseHandle struct {
	client *redis.Client
	key    string
	token  string
	ttl    time.Duration
	script *redis.Script
	renew  *redis.Script
}

func (h *redisLeaseHandle) RenewInterval() time.Duration {
	if h == nil || h.ttl <= 0 {
		return time.Second
	}
	interval := h.ttl / 3
	if interval <= 0 {
		return time.Millisecond
	}
	return interval
}

func (h *redisLeaseHandle) Renew(ctx context.Context) error {
	if h == nil || h.client == nil || h.renew == nil || h.ttl <= 0 {
		return ErrUnavailable
	}

	renewCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()

	result, err := h.renew.Run(
		renewCtx,
		h.client,
		[]string{h.key},
		h.token,
		strconv.FormatInt(h.ttl.Milliseconds(), 10),
	).Int()
	if err != nil {
		return fmt.Errorf("%w: %v", ErrUnavailable, err)
	}
	if result != 1 {
		return ErrLost
	}
	return nil
}

func (h *redisLeaseHandle) Release(ctx context.Context) error {
	if h == nil || h.client == nil {
		return nil
	}

	releaseCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()

	return h.script.Run(
		releaseCtx,
		h.client,
		[]string{h.key},
		h.token,
	).Err()
}
