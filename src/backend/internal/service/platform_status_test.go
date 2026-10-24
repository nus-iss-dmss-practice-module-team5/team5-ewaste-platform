package service

import (
	"context"
	"errors"
	"sync/atomic"
	"testing"
	"time"

	"workflow-api/internal/dto"
	"workflow-api/internal/health"
	"workflow-api/internal/model"
	"workflow-api/internal/monitor"
	"workflow-api/internal/repository"
)

var platformNow = time.Date(2026, 10, 21, 14, 2, 11, 0, time.UTC)

type platformRepoStub struct {
	reads       atomic.Int32
	validateErr error
	outbox      *model.OutboxSummary
	outboxErr   error
	outboxDelay time.Duration
	evidence    *model.EvidenceSummary
}

func (s *platformRepoStub) ValidateAdmin(context.Context, string) error {
	s.reads.Add(1)
	return s.validateErr
}

func (s *platformRepoStub) SummariseOutbox(ctx context.Context, _ int) (*model.OutboxSummary, error) {
	s.reads.Add(1)
	if s.outboxDelay > 0 {
		select {
		case <-time.After(s.outboxDelay):
		case <-ctx.Done():
			return nil, ctx.Err()
		}
	}
	if s.outboxErr != nil {
		return nil, s.outboxErr
	}
	if s.outbox != nil {
		return s.outbox, nil
	}
	return &model.OutboxSummary{}, nil
}

func (s *platformRepoStub) SummariseEvidence(context.Context) (*model.EvidenceSummary, error) {
	s.reads.Add(1)
	if s.evidence != nil {
		return s.evidence, nil
	}
	return &model.EvidenceSummary{CompletedBatches: 128, WithEvidence: 120}, nil
}

type readinessStub struct {
	reads  atomic.Int32
	report health.Report
}

func (s *readinessStub) CheckDetailed(context.Context) (health.Report, error) {
	s.reads.Add(1)
	if s.report.Status != "ready" {
		return s.report, errors.New("dependency down")
	}
	return s.report, nil
}

type telemetryStub struct {
	reads      atomic.Int32
	latency    monitor.Latency
	latencyErr error
	lag        monitor.ConsumerLag
	failures   int64
}

func (s *telemetryStub) Latency(context.Context, time.Duration) (monitor.Latency, error) {
	s.reads.Add(1)
	return s.latency, s.latencyErr
}

func (s *telemetryStub) ConsumerLag(context.Context) (monitor.ConsumerLag, error) {
	s.reads.Add(1)
	return s.lag, nil
}

func (s *telemetryStub) ProcessingFailures(context.Context, time.Duration) (int64, error) {
	s.reads.Add(1)
	return s.failures, nil
}

func healthyTelemetry() *telemetryStub {
	read := new(platformNow.Add(-5 * time.Minute))
	sampled := new(platformNow.Add(-40 * time.Second))
	return &telemetryStub{
		latency: monitor.Latency{APIP95Ms: new(388.0), APISamples: 1204, EventP95Ms: new(1240.0), EventSamples: 96, LastSampleAt: read},
		lag:     monitor.ConsumerLag{Records: new(int64(0)), Partitions: 3, OldestSampledAt: sampled},
	}
}

func ready() *readinessStub {
	return &readinessStub{report: health.Report{Status: "ready", MySQL: "ok", Redis: "ok"}}
}

func releaseSettings() PlatformStatusSettings {
	return PlatformStatusSettings{
		Environment: "prod", WorkbookURL: "https://portal.azure.com/#workbook",
		Release: PlatformRelease{
			ID: "s4-rc2", Commit: "4f1c2a9", DeployedAt: "2026-10-21T09:14:00Z",
			GateRunURL: "https://github.com/org/repo/actions/runs/412", GateDecision: "pass",
			Images: []dto.ReleaseImageView{
				{Name: "workflow-api", Digest: "sha256:9b1e"}, {Name: "workflow-ui", Digest: "sha256:52aa"},
				{Name: "workflow-analytics", Digest: ""},
			},
			RollbackID:     "s4-rc1",
			RollbackImages: []dto.ReleaseImageView{{Name: "workflow-api", Digest: "sha256:7e21"}},
		},
	}
}

func newPlatformService(repo *platformRepoStub, readiness ReadinessChecker, telemetry monitor.Reader, settings PlatformStatusSettings) *PlatformStatusService {
	s := NewPlatformStatusService(repo, readiness, telemetry, settings)
	s.now = func() time.Time { return platformNow }
	return s
}

var admin = WorkflowReadActor{UserID: "USR-005", OrganisationID: "PLATFORM", RoleCode: "SYSTEM_ADMIN"}

func TestPlatformStatusRefusesEveryOtherRoleBeforeAnyRead(t *testing.T) {
	for _, role := range []string{"AUDITOR", "RECYCLER", "DONOR", "COLLECTOR", "", "system_administrator"} {
		repo, readiness, telemetry := &platformRepoStub{}, ready(), healthyTelemetry()
		_, err := newPlatformService(repo, readiness, telemetry, releaseSettings()).
			Status(context.Background(), WorkflowReadActor{UserID: "USR-001", RoleCode: role})
		if !errors.Is(err, ErrWorkflowReadForbidden) {
			t.Fatalf("%q: err = %v, want forbidden", role, err)
		}
		if repo.reads.Load()+readiness.reads.Load()+telemetry.reads.Load() != 0 {
			t.Fatalf("%q: a source was read before the role check", role)
		}
	}
}

func TestPlatformStatusRefusesAnAdminTokenWhoseUserIsNoLongerAnAdmin(t *testing.T) {
	repo, telemetry := &platformRepoStub{validateErr: repository.ErrWorkflowReadForbidden}, healthyTelemetry()

	_, err := newPlatformService(repo, ready(), telemetry, releaseSettings()).Status(context.Background(), admin)

	if !errors.Is(err, ErrWorkflowReadForbidden) || telemetry.reads.Load() != 0 {
		t.Fatalf("err = %v, telemetry reads = %d", err, telemetry.reads.Load())
	}
}

func TestPlatformStatusAllWithinTargetIsOK(t *testing.T) {
	view, err := newPlatformService(&platformRepoStub{}, ready(), healthyTelemetry(), releaseSettings()).Status(context.Background(), admin)

	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if view.Summary != PlatformSummaryOK || len(view.Unknown) != 0 {
		t.Fatalf("summary = %s unknown = %v", view.Summary, view.Unknown)
	}
	if view.ReadAt != platformNow || *view.Environment != "prod" || view.Readiness.MySQL != "ok" {
		t.Fatalf("header = %+v", view)
	}
	if *view.Latency.APIP95Ms != 388 || view.Latency.WindowMinutes != 15 || *view.ConsumerLag.Records != 0 {
		t.Fatalf("telemetry = %+v %+v", view.Latency, view.ConsumerLag)
	}
	if view.Evidence.WithoutEvidence != 8 || *view.ProcessingFailuresLastHour != 0 {
		t.Fatalf("evidence = %+v", view.Evidence)
	}
	release := view.Release
	if release.ID != "s4-rc2" || *release.GateDecision != "PASS" || release.DeployedAt == nil || len(release.Images) != 2 {
		t.Fatalf("release = %+v", release)
	}
	if release.RollbackTarget == nil || release.RollbackTarget.ID != "s4-rc1" || len(release.RollbackTarget.Images) != 1 {
		t.Fatalf("rollback = %+v", release.RollbackTarget)
	}
}

func TestPlatformStatusDeadLetteredEventsNeedAttention(t *testing.T) {
	code := "BROKER_TIMEOUT"
	repo := &platformRepoStub{outbox: &model.OutboxSummary{Quarantined: 2, RecentQuarantined: []model.QuarantinedEvent{
		{EventType: "TreatmentRecorded", SchemaVersion: 1, BatchID: "ae95ae4f", AttemptCount: 8, LastErrorCode: &code, CreatedAt: platformNow, CorrelationID: "corr-8f31c2"},
	}}}

	view, err := newPlatformService(repo, ready(), healthyTelemetry(), releaseSettings()).Status(context.Background(), admin)

	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if view.Summary != PlatformSummaryAttention {
		t.Fatalf("summary = %s err = %v", view.Summary, err)
	}
	if got := view.Outbox.RecentQuarantined[0]; got.BatchID != "ae95ae4f" || *got.LastErrorCode != code || got.AttemptCount != 8 {
		t.Fatalf("quarantined = %+v", got)
	}
}

func TestPlatformStatusLatencyOverTargetNeedsAttention(t *testing.T) {
	telemetry := healthyTelemetry()
	telemetry.latency.APIP95Ms = new(3400.0)

	view, _ := newPlatformService(&platformRepoStub{}, ready(), telemetry, releaseSettings()).Status(context.Background(), admin)

	if view.Summary != PlatformSummaryAttention {
		t.Fatalf("summary = %s", view.Summary)
	}
}

func TestPlatformStatusNotReadyWinsOverEverythingElse(t *testing.T) {
	readiness := &readinessStub{report: health.Report{Status: "not_ready", MySQL: "ok", Redis: "unavailable"}}
	repo := &platformRepoStub{outbox: &model.OutboxSummary{Quarantined: 1}}

	view, err := newPlatformService(repo, readiness, nil, releaseSettings()).Status(context.Background(), admin)

	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if view.Summary != PlatformSummaryNotReady || view.Readiness.Redis != "unavailable" {
		t.Fatalf("summary = %s readiness = %+v err = %v", view.Summary, view.Readiness, err)
	}
}

func TestPlatformStatusWithoutLogAnalyticsReportsUnknownNotZero(t *testing.T) {
	view, err := newPlatformService(&platformRepoStub{}, ready(), nil, releaseSettings()).Status(context.Background(), admin)

	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if view.Summary != PlatformSummaryUnknown {
		t.Fatalf("summary = %s err = %v", view.Summary, err)
	}
	if view.Latency != nil || view.ConsumerLag != nil || view.ProcessingFailuresLastHour != nil {
		t.Fatalf("unconfigured telemetry was filled in: %+v", view)
	}
	for _, source := range []string{"latency", "consumer_lag", "processing_failures"} {
		if view.Unknown[source] != UnknownNotConfigured {
			t.Fatalf("unknown[%s] = %q", source, view.Unknown[source])
		}
	}
	if view.Readiness.Status != "ready" || view.Outbox == nil || view.Evidence == nil {
		t.Fatalf("database and readiness tiles should still show: %+v", view)
	}
}

func TestPlatformStatusFailedLogQueryOnlyBlanksItsOwnTile(t *testing.T) {
	telemetry := healthyTelemetry()
	telemetry.latencyErr = monitor.ErrQueryFailed

	view, _ := newPlatformService(&platformRepoStub{}, ready(), telemetry, releaseSettings()).Status(context.Background(), admin)

	if view.Latency != nil || view.Unknown["latency"] != UnknownQueryFailed || view.ConsumerLag == nil {
		t.Fatalf("latency = %+v unknown = %v", view.Latency, view.Unknown)
	}
	if view.Summary != PlatformSummaryUnknown {
		t.Fatalf("summary = %s", view.Summary)
	}
}

func TestPlatformStatusSlowSourceTimesOutAlone(t *testing.T) {
	repo := &platformRepoStub{outboxDelay: time.Second}
	s := newPlatformService(repo, ready(), healthyTelemetry(), releaseSettings())
	s.budget = 20 * time.Millisecond

	started := time.Now()
	view, err := s.Status(context.Background(), admin)

	if err != nil {
		t.Fatalf("status: %v", err)
	}
	if time.Since(started) > 500*time.Millisecond {
		t.Fatalf("err = %v elapsed = %s", err, time.Since(started))
	}
	if view.Outbox != nil || view.Unknown["outbox"] != UnknownTimedOut || view.Evidence == nil || view.Latency == nil {
		t.Fatalf("outbox = %+v unknown = %v", view.Outbox, view.Unknown)
	}
}

func TestPlatformStatusStaleSamplesAreUnknown(t *testing.T) {
	telemetry := healthyTelemetry()
	oldRead := new(platformNow.Add(-16 * time.Minute))
	oldSample := new(platformNow.Add(-6 * time.Minute))
	telemetry.latency.LastSampleAt = oldRead
	telemetry.lag.OldestSampledAt = oldSample

	view, _ := newPlatformService(&platformRepoStub{}, ready(), telemetry, releaseSettings()).Status(context.Background(), admin)

	if view.Latency != nil || view.Unknown["latency"] != UnknownStaleSample {
		t.Fatalf("latency = %+v unknown = %v", view.Latency, view.Unknown)
	}
	// The tile keeps the sample time so it can say how old it is.
	if view.ConsumerLag == nil || view.ConsumerLag.Records != nil || !view.ConsumerLag.SampledAt.Equal(*oldSample) || view.Unknown["consumer_lag"] != UnknownStaleSample {
		t.Fatalf("lag = %+v unknown = %v", view.ConsumerLag, view.Unknown)
	}
}

func TestPlatformStatusWithoutReleaseValuesSaysNotRecorded(t *testing.T) {
	view, _ := newPlatformService(&platformRepoStub{}, ready(), healthyTelemetry(), PlatformStatusSettings{}).Status(context.Background(), admin)

	if view.Release != nil || view.Unknown["release"] != UnknownNotRecorded || view.Environment != nil {
		t.Fatalf("release = %+v unknown = %v", view.Release, view.Unknown)
	}
	// A missing release record is not a health signal.
	if view.Summary != PlatformSummaryOK {
		t.Fatalf("summary = %s", view.Summary)
	}
}
