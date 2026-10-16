// Package monitor reads the platform's own telemetry back from Log Analytics
// for the Administrator health view. The queries reuse the EWCSB-183 filters
// (docs/monitoring/processing-*.kql) and only summarise them for one tile.
package monitor

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"regexp"
	"strings"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
)

var (
	// ErrNotConfigured means no workspace is set for this deployment.
	ErrNotConfigured = errors.New("monitor: log analytics is not configured")
	// ErrQueryFailed covers transport, auth and query errors alike. The
	// caller shows the signal as unknown; the cause stays in the server log.
	ErrQueryFailed = errors.New("monitor: log analytics query failed")
)

const (
	defaultEndpoint   = "https://api.loganalytics.io"
	logAnalyticsScope = "https://api.loganalytics.io/.default"
	maxResponseBytes  = 1 << 20
)

// Latency is the P95 of per-stage durations over the window. A nil P95 means
// no sample of that kind arrived in the window.
type Latency struct {
	APIP95Ms     *float64
	APISamples   int64
	EventP95Ms   *float64
	EventSamples int64
	LastSampleAt *time.Time
}

// ConsumerLag is the latest sample per partition, added up. Records is nil
// when any partition has no usable sample: no sample is not zero lag.
type ConsumerLag struct {
	Records         *int64
	Partitions      int64
	OldestSampledAt *time.Time
}

type Reader interface {
	Latency(ctx context.Context, window time.Duration) (Latency, error)
	ConsumerLag(ctx context.Context) (ConsumerLag, error)
	ProcessingFailures(ctx context.Context, window time.Duration) (int64, error)
}

type LogAnalyticsReader struct {
	workspaceID string
	appPrefix   string
	endpoint    string
	credential  azcore.TokenCredential
	client      *http.Client
}

var appPrefixPattern = regexp.MustCompile(`^[a-z0-9-]{1,64}$`)

// NewLogAnalyticsReader returns a reader for one workspace. The app prefix
// is spliced into KQL, so it must be a plain Container App name prefix.
func NewLogAnalyticsReader(workspaceID, appPrefix string, credential azcore.TokenCredential, client *http.Client) (*LogAnalyticsReader, error) {
	workspaceID = strings.TrimSpace(workspaceID)
	if workspaceID == "" || credential == nil {
		return nil, ErrNotConfigured
	}
	if !appPrefixPattern.MatchString(appPrefix) {
		return nil, fmt.Errorf("monitor: invalid container app prefix %q", appPrefix)
	}
	if client == nil {
		client = &http.Client{}
	}
	return &LogAnalyticsReader{
		workspaceID: workspaceID, appPrefix: appPrefix, endpoint: defaultEndpoint,
		credential: credential, client: client,
	}, nil
}

// WithEndpoint points the reader at another query host (tests, sovereign clouds).
func (r *LogAnalyticsReader) WithEndpoint(endpoint string) *LogAnalyticsReader {
	r.endpoint = strings.TrimRight(endpoint, "/")
	return r
}

// signals is the shared prelude of the EWCSB-183 queries, unchanged apart
// from the prefix and lookback.
func (r *LogAnalyticsReader) signals(lookback time.Duration) string {
	return fmt.Sprintf(`let AppPrefix = %q;
let Lookback = %dm;
let Signals = union isfuzzy=true
    (ContainerAppConsoleLogs_CL | project TimeGenerated, App=tostring(ContainerAppName_s), Message=tostring(Log_s)),
    (ContainerAppConsoleLogs | project TimeGenerated, App=tostring(ContainerAppName), Message=tostring(Log))
| where TimeGenerated > ago(Lookback) and App startswith AppPrefix
| extend j=parse_json(Message)
| where toint(j.telemetry_version)==1
| extend Observation=tostring(j.observation), Outcome=tostring(j.outcome), Code=tostring(j.code),
         Correlation=tostring(j.correlation_id), Batch=tostring(j.batch_id),
         Operation=tostring(j.operation), DurationMs=todouble(j.duration_ms);
`, r.appPrefix, int(lookback/time.Minute))
}

// Latency follows query 2 (processing-latency.kql), split into the API's own
// HTTP requests and the event stages behind them.
func (r *LogAnalyticsReader) Latency(ctx context.Context, window time.Duration) (Latency, error) {
	query := r.signals(window) + `Signals
| where Observation in ("http_request","outbox_published","processing_step")
| where isnotnull(DurationMs)
| extend Kind=iff(Observation == "http_request", "api", "event")
| summarize Samples=count(), P95Ms=percentile(DurationMs,95), LastSample=max(TimeGenerated) by Kind`
	rows, err := r.query(ctx, query)
	if err != nil {
		return Latency{}, err
	}
	var result Latency
	for _, row := range rows {
		samples := row.int("Samples")
		p95 := row.float("P95Ms")
		switch row.string("Kind") {
		case "api":
			result.APISamples = samples
			result.APIP95Ms = p95
		case "event":
			result.EventSamples = samples
			result.EventP95Ms = p95
		}
		if last := row.time("LastSample"); last != nil && (result.LastSampleAt == nil || last.After(*result.LastSampleAt)) {
			result.LastSampleAt = last
		}
	}
	return result, nil
}

// ConsumerLag follows query 3 (processing-consumer-lag.kql): the newest
// sample per partition, null when stale (over 90 s) or unavailable.
func (r *LogAnalyticsReader) ConsumerLag(ctx context.Context) (ConsumerLag, error) {
	query := r.signals(time.Hour) + `Signals
| where Observation == "consumer_lag" and isnotnull(j.partition)
| extend ConsumerGroup=tostring(j.consumer_group), Topic=tostring(j.topic), Partition=toint(j.partition)
| summarize arg_max(TimeGenerated,*) by App,ConsumerGroup,Topic,Partition
| extend Stale=TimeGenerated < ago(90s), Available=tobool(j.sample_available)
| project LastSample=TimeGenerated, Lag=iif(Available and not(Stale),tolong(j.consumer_lag),long(null))
| summarize Partitions=count(), Missing=countif(isnull(Lag)), Records=sum(Lag), OldestSample=min(LastSample)`
	rows, err := r.query(ctx, query)
	if err != nil {
		return ConsumerLag{}, err
	}
	if len(rows) == 0 {
		return ConsumerLag{}, nil
	}
	row := rows[0]
	result := ConsumerLag{Partitions: row.int("Partitions"), OldestSampledAt: row.time("OldestSample")}
	if result.Partitions > 0 && row.int("Missing") == 0 {
		records := row.int("Records")
		result.Records = &records
	}
	return result, nil
}

// ProcessingFailures follows query 4 (processing-failures-retries.kql) and
// counts failed, retrying, quarantined and rejected observations.
func (r *LogAnalyticsReader) ProcessingFailures(ctx context.Context, window time.Duration) (int64, error) {
	query := r.signals(window) + `Signals
| where Outcome in ("FAILED","RETRYING","QUARANTINED","REJECTED")
| summarize Attempts=count()`
	rows, err := r.query(ctx, query)
	if err != nil {
		return 0, err
	}
	if len(rows) == 0 {
		return 0, nil
	}
	return rows[0].int("Attempts"), nil
}

type queryResponse struct {
	Tables []struct {
		Columns []struct {
			Name string `json:"name"`
		} `json:"columns"`
		Rows [][]any `json:"rows"`
	} `json:"tables"`
}

type resultRow map[string]any

func (r *LogAnalyticsReader) query(ctx context.Context, kql string) ([]resultRow, error) {
	token, err := r.credential.GetToken(ctx, policy.TokenRequestOptions{Scopes: []string{logAnalyticsScope}})
	if err != nil {
		return nil, fmt.Errorf("%w: token: %v", ErrQueryFailed, err)
	}
	body, err := json.Marshal(map[string]string{"query": kql})
	if err != nil {
		return nil, fmt.Errorf("%w: encode: %v", ErrQueryFailed, err)
	}
	request, err := http.NewRequestWithContext(ctx, http.MethodPost, r.endpoint+"/v1/workspaces/"+r.workspaceID+"/query", bytes.NewReader(body))
	if err != nil {
		return nil, fmt.Errorf("%w: request: %v", ErrQueryFailed, err)
	}
	request.Header.Set("Authorization", "Bearer "+token.Token)
	request.Header.Set("Content-Type", "application/json")
	response, err := r.client.Do(request)
	if err != nil {
		return nil, fmt.Errorf("%w: %v", ErrQueryFailed, err)
	}
	defer response.Body.Close()
	payload, err := io.ReadAll(io.LimitReader(response.Body, maxResponseBytes))
	if err != nil {
		return nil, fmt.Errorf("%w: read: %v", ErrQueryFailed, err)
	}
	if response.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("%w: status %d", ErrQueryFailed, response.StatusCode)
	}
	var decoded queryResponse
	if err := json.Unmarshal(payload, &decoded); err != nil {
		return nil, fmt.Errorf("%w: decode: %v", ErrQueryFailed, err)
	}
	if len(decoded.Tables) == 0 {
		return nil, nil
	}
	table := decoded.Tables[0]
	rows := make([]resultRow, 0, len(table.Rows))
	for _, values := range table.Rows {
		row := resultRow{}
		for index, column := range table.Columns {
			if index < len(values) {
				row[column.Name] = values[index]
			}
		}
		rows = append(rows, row)
	}
	return rows, nil
}

func (row resultRow) string(key string) string {
	value, _ := row[key].(string)
	return value
}

// Log Analytics returns long and real columns as JSON numbers.
func (row resultRow) float(key string) *float64 {
	value, ok := row[key].(float64)
	if !ok {
		return nil
	}
	return &value
}

func (row resultRow) int(key string) int64 {
	value, _ := row[key].(float64)
	return int64(value)
}

func (row resultRow) time(key string) *time.Time {
	value, ok := row[key].(string)
	if !ok || value == "" {
		return nil
	}
	parsed, err := time.Parse(time.RFC3339Nano, value)
	if err != nil {
		return nil
	}
	parsed = parsed.UTC()
	return &parsed
}
