package monitor

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"github.com/Azure/azure-sdk-for-go/sdk/azcore"
	"github.com/Azure/azure-sdk-for-go/sdk/azcore/policy"
)

type fakeCredential struct{ scopes []string }

func (c *fakeCredential) GetToken(_ context.Context, options policy.TokenRequestOptions) (azcore.AccessToken, error) {
	c.scopes = options.Scopes
	return azcore.AccessToken{Token: "la-token", ExpiresOn: time.Now().Add(time.Hour)}, nil
}

type table struct {
	Columns []map[string]string `json:"columns"`
	Rows    [][]any             `json:"rows"`
}

func serve(t *testing.T, status int, columns []string, rows [][]any) (*LogAnalyticsReader, *string) {
	t.Helper()
	var lastQuery string
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/workspaces/ws-123/query" || r.Header.Get("Authorization") != "Bearer la-token" {
			t.Errorf("unexpected request %s %s", r.URL.Path, r.Header.Get("Authorization"))
		}
		var body struct {
			Query string `json:"query"`
		}
		_ = json.NewDecoder(r.Body).Decode(&body)
		lastQuery = body.Query
		w.WriteHeader(status)
		cols := make([]map[string]string, 0, len(columns))
		for _, name := range columns {
			cols = append(cols, map[string]string{"name": name})
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"tables": []table{{Columns: cols, Rows: rows}}})
	}))
	t.Cleanup(server.Close)
	reader, err := NewLogAnalyticsReader("ws-123", "aca-ewaste-prod-", &fakeCredential{}, server.Client())
	if err != nil {
		t.Fatalf("new reader: %v", err)
	}
	return reader.WithEndpoint(server.URL), &lastQuery
}

func TestLatencySplitsAPIAndEventStages(t *testing.T) {
	reader, query := serve(t, http.StatusOK, []string{"Kind", "Samples", "P95Ms", "LastSample"}, [][]any{
		{"api", 1204, 388.4, "2026-10-21T13:57:00Z"},
		{"event", 96, 1240.0, "2026-10-21T13:58:30.5Z"},
	})

	latency, err := reader.Latency(context.Background(), 15*time.Minute)

	if err != nil {
		t.Fatalf("latency: %v", err)
	}
	if *latency.APIP95Ms != 388.4 || latency.APISamples != 1204 || *latency.EventP95Ms != 1240 || latency.EventSamples != 96 {
		t.Fatalf("latency = %+v", latency)
	}
	if !latency.LastSampleAt.Equal(time.Date(2026, 10, 21, 13, 58, 30, 500_000_000, time.UTC)) {
		t.Fatalf("last sample = %v", latency.LastSampleAt)
	}
	for _, part := range []string{`let AppPrefix = "aca-ewaste-prod-"`, "let Lookback = 15m", `Observation in ("http_request","outbox_published","processing_step")`} {
		if !strings.Contains(*query, part) {
			t.Fatalf("query is missing %q:\n%s", part, *query)
		}
	}
}

func TestConsumerLagIsNullWhenAnyPartitionHasNoUsableSample(t *testing.T) {
	reader, _ := serve(t, http.StatusOK, []string{"Partitions", "Missing", "Records", "OldestSample"}, [][]any{{3, 1, 0, "2026-10-21T14:01:31Z"}})

	lag, err := reader.ConsumerLag(context.Background())

	if err != nil || lag.Records != nil || lag.Partitions != 3 || lag.OldestSampledAt == nil {
		t.Fatalf("lag = %+v err = %v", lag, err)
	}
}

func TestConsumerLagAddsUpPartitions(t *testing.T) {
	reader, query := serve(t, http.StatusOK, []string{"Partitions", "Missing", "Records", "OldestSample"}, [][]any{{3, 0, 7, "2026-10-21T14:01:31Z"}})

	lag, err := reader.ConsumerLag(context.Background())

	if err != nil || lag.Records == nil || *lag.Records != 7 {
		t.Fatalf("lag = %+v err = %v", lag, err)
	}
	if !strings.Contains(*query, "Stale=TimeGenerated < ago(90s)") {
		t.Fatalf("query lost the 90 s stale rule:\n%s", *query)
	}
}

func TestProcessingFailuresCountsQuery4Outcomes(t *testing.T) {
	reader, query := serve(t, http.StatusOK, []string{"Attempts"}, [][]any{{3}})

	failures, err := reader.ProcessingFailures(context.Background(), time.Hour)

	if err != nil || failures != 3 || !strings.Contains(*query, `Outcome in ("FAILED","RETRYING","QUARANTINED","REJECTED")`) {
		t.Fatalf("failures = %d err = %v query = %s", failures, err, *query)
	}
}

func TestQueryErrorsAreReportedAsQueryFailed(t *testing.T) {
	reader, _ := serve(t, http.StatusForbidden, nil, nil)

	_, err := reader.Latency(context.Background(), 15*time.Minute)

	if !errors.Is(err, ErrQueryFailed) {
		t.Fatalf("err = %v, want ErrQueryFailed", err)
	}
}

func TestReaderNeedsAWorkspaceAndAPlainPrefix(t *testing.T) {
	if _, err := NewLogAnalyticsReader("", "aca-ewaste-prod-", &fakeCredential{}, nil); !errors.Is(err, ErrNotConfigured) {
		t.Fatalf("empty workspace: err = %v", err)
	}
	if _, err := NewLogAnalyticsReader("ws-123", `x"; drop`, &fakeCredential{}, nil); err == nil {
		t.Fatal("a prefix that could break out of the KQL string was accepted")
	}
}
