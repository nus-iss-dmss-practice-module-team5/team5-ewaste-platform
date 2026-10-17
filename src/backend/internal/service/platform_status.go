package service

import (
	"context"
	"errors"
	"strings"
	"sync"
	"time"

	"workflow-api/internal/dto"
	"workflow-api/internal/health"
	"workflow-api/internal/model"
	"workflow-api/internal/monitor"
	"workflow-api/internal/repository"
)

const (
	PlatformSummaryOK        = "OK"
	PlatformSummaryAttention = "ATTENTION"
	PlatformSummaryNotReady  = "NOT_READY"
	PlatformSummaryUnknown   = "UNKNOWN"

	// Reasons a source is reported as unknown.
	UnknownNotConfigured = "NOT_CONFIGURED"
	UnknownQueryFailed   = "LOG_QUERY_FAILED"
	UnknownTimedOut      = "TIMED_OUT"
	UnknownNoSample      = "NO_SAMPLE"
	UnknownStaleSample   = "STALE_SAMPLE"
	UnknownReadFailed    = "READ_FAILED"
	UnknownNotRecorded   = "NOT_RECORDED"
)

// Targets shared with the EWCSB-223 alert rules.
const (
	latencyWindow       = 15 * time.Minute
	failureWindow       = time.Hour
	latencyMaxAge       = 15 * time.Minute
	lagMaxAge           = 90 * time.Second
	apiP95TargetMs      = 3000
	eventP95TargetMs    = 10000
	consumerLagTarget   = 100
	recentQuarantined   = 5
	defaultSourceBudget = 3 * time.Second
)

type ReadinessChecker interface {
	CheckDetailed(ctx context.Context) (health.Report, error)
}

// PlatformRelease is what the deploy job stamped on this container.
type PlatformRelease struct {
	ID, Commit, DeployedAt, GateRunURL, GateDecision string
	Images                                           []dto.ReleaseImageView
	RollbackID, RollbackCommit, RollbackGateRunURL   string
	RollbackImages                                   []dto.ReleaseImageView
}

type PlatformStatusSettings struct {
	Environment string
	WorkbookURL string
	Release     PlatformRelease
}

type PlatformStatusService struct {
	repository repository.PlatformStatusRepository
	readiness  ReadinessChecker
	telemetry  monitor.Reader
	settings   PlatformStatusSettings
	budget     time.Duration
	now        func() time.Time
}

// NewPlatformStatusService builds the Admin read. A nil telemetry reader
// means Log Analytics is not configured for this deployment.
func NewPlatformStatusService(repo repository.PlatformStatusRepository, readiness ReadinessChecker, telemetry monitor.Reader, settings PlatformStatusSettings) *PlatformStatusService {
	return &PlatformStatusService{
		repository: repo, readiness: readiness, telemetry: telemetry, settings: settings,
		budget: defaultSourceBudget, now: func() time.Time { return time.Now().UTC() },
	}
}

// Status reads every source in parallel, each on its own budget, so one slow
// source makes only its own fields unknown. Every other role is refused
// before any read.
func (s *PlatformStatusService) Status(ctx context.Context, actor WorkflowReadActor) (dto.PlatformStatusView, error) {
	if !isRole(actor.RoleCode, "SYSTEM_ADMIN") {
		return dto.PlatformStatusView{}, ErrWorkflowReadForbidden
	}
	if err := s.repository.ValidateAdmin(ctx, actor.UserID); err != nil {
		return dto.PlatformStatusView{}, mapWorkflowReadRepositoryError(err)
	}

	view := dto.PlatformStatusView{ReadAt: s.now(), Unknown: map[string]string{}}
	view.Environment = trimmedOrNil(s.settings.Environment)
	view.WorkbookURL = trimmedOrNil(s.settings.WorkbookURL)
	view.Release = s.release()
	if view.Release == nil {
		view.Unknown["release"] = UnknownNotRecorded
	}

	var mu sync.Mutex
	unknown := func(source, reason string) {
		mu.Lock()
		view.Unknown[source] = reason
		mu.Unlock()
	}
	var wg sync.WaitGroup
	run := func(read func(context.Context)) {
		wg.Go(func() {
			sourceCtx, cancel := context.WithTimeout(ctx, s.budget)
			defer cancel()
			read(sourceCtx)
		})
	}

	run(func(ctx context.Context) { view.Readiness = s.readReadiness(ctx) })
	run(func(ctx context.Context) {
		outbox, err := s.repository.SummariseOutbox(ctx, recentQuarantined)
		if err != nil {
			unknown("outbox", reasonFor(ctx, err))
			return
		}
		view.Outbox = outboxToDTO(outbox)
	})
	run(func(ctx context.Context) {
		evidence, err := s.repository.SummariseEvidence(ctx)
		if err != nil {
			unknown("evidence", reasonFor(ctx, err))
			return
		}
		view.Evidence = &dto.EvidenceCountView{
			CompletedBatches: evidence.CompletedBatches, WithEvidence: evidence.WithEvidence,
			WithoutEvidence: evidence.CompletedBatches - evidence.WithEvidence,
		}
	})
	if s.telemetry == nil {
		for _, source := range []string{"latency", "consumer_lag", "processing_failures"} {
			view.Unknown[source] = UnknownNotConfigured
		}
	} else {
		run(func(ctx context.Context) {
			latency, reason := s.readLatency(ctx)
			if reason != "" {
				unknown("latency", reason)
				return
			}
			view.Latency = latency
		})
		run(func(ctx context.Context) {
			lag, reason := s.readConsumerLag(ctx)
			if reason != "" {
				unknown("consumer_lag", reason)
			}
			view.ConsumerLag = lag
		})
		run(func(ctx context.Context) {
			failures, err := s.telemetry.ProcessingFailures(ctx, failureWindow)
			if err != nil {
				unknown("processing_failures", reasonFor(ctx, err))
				return
			}
			view.ProcessingFailuresLastHour = &failures
		})
	}
	wg.Wait()

	view.Summary = summarise(view)
	return view, nil
}

func (s *PlatformStatusService) readReadiness(ctx context.Context) dto.ReadinessView {
	if s.readiness == nil {
		return dto.ReadinessView{Status: "not_ready", MySQL: "unavailable", Redis: "unavailable"}
	}
	// The report already says which dependency failed; the error adds nothing
	// the Admin may see.
	report, _ := s.readiness.CheckDetailed(ctx)
	return dto.ReadinessView{Status: report.Status, MySQL: report.MySQL, Redis: report.Redis}
}

func (s *PlatformStatusService) readLatency(ctx context.Context) (*dto.LatencyView, string) {
	latency, err := s.telemetry.Latency(ctx, latencyWindow)
	if err != nil {
		return nil, reasonFor(ctx, err)
	}
	if latency.LastSampleAt == nil || (latency.APISamples == 0 && latency.EventSamples == 0) {
		return nil, UnknownNoSample
	}
	if s.now().Sub(*latency.LastSampleAt) > latencyMaxAge {
		return nil, UnknownStaleSample
	}
	return &dto.LatencyView{
		APIP95Ms: latency.APIP95Ms, APISamples: latency.APISamples,
		EventP95Ms: latency.EventP95Ms, EventSamples: latency.EventSamples,
		WindowMinutes: int(latencyWindow / time.Minute), ReadAt: *latency.LastSampleAt,
	}, ""
}

// readConsumerLag keeps the sample time when the count is unusable, so the
// tile can say how old the last sample is.
func (s *PlatformStatusService) readConsumerLag(ctx context.Context) (*dto.ConsumerLagView, string) {
	lag, err := s.telemetry.ConsumerLag(ctx)
	if err != nil {
		return nil, reasonFor(ctx, err)
	}
	if lag.Partitions == 0 || lag.OldestSampledAt == nil {
		return nil, UnknownNoSample
	}
	view := &dto.ConsumerLagView{Records: lag.Records, Partitions: lag.Partitions, SampledAt: lag.OldestSampledAt}
	if s.now().Sub(*lag.OldestSampledAt) > lagMaxAge {
		view.Records = nil
		return view, UnknownStaleSample
	}
	if lag.Records == nil {
		return view, UnknownNoSample
	}
	return view, ""
}

func (s *PlatformStatusService) release() *dto.ReleaseView {
	r := s.settings.Release
	if strings.TrimSpace(r.ID) == "" {
		return nil
	}
	view := &dto.ReleaseView{
		ID: r.ID, Commit: trimmedOrNil(r.Commit), GateRunURL: trimmedOrNil(r.GateRunURL),
		GateDecision: trimmedOrNil(strings.ToUpper(strings.TrimSpace(r.GateDecision))),
		Images:       nonEmptyImages(r.Images),
	}
	if deployedAt, err := time.Parse(time.RFC3339, strings.TrimSpace(r.DeployedAt)); err == nil {
		utc := deployedAt.UTC()
		view.DeployedAt = &utc
	}
	if strings.TrimSpace(r.RollbackID) != "" {
		view.RollbackTarget = &dto.RollbackView{
			ID: r.RollbackID, Commit: trimmedOrNil(r.RollbackCommit), GateRunURL: trimmedOrNil(r.RollbackGateRunURL),
			Images: nonEmptyImages(r.RollbackImages),
		}
	}
	return view
}

// summarise takes the worst tile: not ready, then attention, then unknown.
// Release details are not a health signal and do not count.
func summarise(view dto.PlatformStatusView) string {
	if view.Readiness.Status != "ready" {
		return PlatformSummaryNotReady
	}
	attention := (view.Outbox != nil && view.Outbox.Quarantined > 0) ||
		(view.Latency != nil && view.Latency.APIP95Ms != nil && *view.Latency.APIP95Ms > apiP95TargetMs) ||
		(view.Latency != nil && view.Latency.EventP95Ms != nil && *view.Latency.EventP95Ms > eventP95TargetMs) ||
		(view.ConsumerLag != nil && view.ConsumerLag.Records != nil && *view.ConsumerLag.Records > consumerLagTarget)
	if attention {
		return PlatformSummaryAttention
	}
	for source := range view.Unknown {
		if source != "release" {
			return PlatformSummaryUnknown
		}
	}
	return PlatformSummaryOK
}

func reasonFor(ctx context.Context, err error) string {
	switch {
	case errors.Is(ctx.Err(), context.DeadlineExceeded) || errors.Is(err, context.DeadlineExceeded):
		return UnknownTimedOut
	case errors.Is(err, monitor.ErrNotConfigured):
		return UnknownNotConfigured
	case errors.Is(err, monitor.ErrQueryFailed):
		return UnknownQueryFailed
	default:
		return UnknownReadFailed
	}
}

func outboxToDTO(summary *model.OutboxSummary) *dto.OutboxStatusView {
	view := &dto.OutboxStatusView{
		Pending: summary.Pending, OldestPendingCreatedAt: summary.OldestPendingCreatedAt,
		Quarantined:       summary.Quarantined,
		RecentQuarantined: make([]dto.QuarantinedEventView, 0, len(summary.RecentQuarantined)),
	}
	for _, event := range summary.RecentQuarantined {
		view.RecentQuarantined = append(view.RecentQuarantined, dto.QuarantinedEventView{
			EventType: event.EventType, SchemaVersion: event.SchemaVersion, BatchID: event.BatchID,
			AttemptCount: event.AttemptCount, LastErrorCode: event.LastErrorCode,
			CreatedAt: event.CreatedAt, CorrelationID: event.CorrelationID,
		})
	}
	return view
}

func nonEmptyImages(images []dto.ReleaseImageView) []dto.ReleaseImageView {
	result := make([]dto.ReleaseImageView, 0, len(images))
	for _, image := range images {
		if strings.TrimSpace(image.Digest) != "" {
			result = append(result, image)
		}
	}
	return result
}

func trimmedOrNil(value string) *string {
	value = strings.TrimSpace(value)
	if value == "" {
		return nil
	}
	return &value
}
