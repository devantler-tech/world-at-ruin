package allocatordiscovery

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"sync"
	"testing"
	"time"

	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/client-go/rest"
	ktesting "k8s.io/client-go/testing"
)

const responseLimitForTest = 4 << 20

type trackingBody struct {
	io.Reader
	read   int
	closed bool
}

// Read counts the bytes consumed from the injected response reader.
func (b *trackingBody) Read(p []byte) (int, error) {
	n, err := b.Reader.Read(p)
	b.read += n
	return n, err
}

// Close records whether the transport released its response body.
func (b *trackingBody) Close() error { b.closed = true; return nil }

type transportFunc func(*http.Request) (*http.Response, error)

// RoundTrip delegates each request to the test's injected transport behavior.
func (f transportFunc) RoundTrip(r *http.Request) (*http.Response, error) { return f(r) }

// readerFromRESTConfig constructs the production bounded transport and fails immediately on
// invalid fixture configuration.
func readerFromRESTConfig(t *testing.T, cfg *rest.Config) *Reader {
	t.Helper()
	r, err := New(cfg, config())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

// listJSON builds a versioned empty Kubernetes list with controlled pagination and padding.
func listJSON(kind, cursor string, padding int) string {
	const version = "rv"
	apiVersion := "v1"
	if kind == "EndpointSliceList" {
		apiVersion = "discovery.k8s.io/v1"
	}
	return "{\"apiVersion\":\"" + apiVersion + "\",\"kind\":\"" + kind + "\",\"metadata\":{\"resourceVersion\":\"" + version + "\",\"continue\":\"" + cursor + "\"},\"items\":[],\"padding\":\"" + strings.Repeat("x", padding) + "\"}"
}

type listResponseFixture struct {
	reader *Reader
	bodies []*trackingBody
}

// newListResponseFixture keeps one reader and a live accounting record of every returned body.
func newListResponseFixture(t *testing.T, padding int, knownLength bool) *listResponseFixture {
	t.Helper()
	f := &listResponseFixture{}
	transport := transportFunc(func(req *http.Request) (*http.Response, error) {
		response, body := trackedListResponse(req, padding, knownLength)
		f.bodies = append(f.bodies, body)
		return response, nil
	})
	f.reader = readerFromRESTConfig(t, &rest.Config{Host: "https://api.example", Transport: transport, Timeout: time.Second})
	return f
}

// assertEmptyDiscovery preserves the independent no-partial-evidence invariant after refusal.
func assertEmptyDiscovery(t *testing.T, got Snapshot, err error, reason string) {
	t.Helper()
	if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) {
		t.Fatalf("%s response returned evidence: %+v, %v", reason, got, err)
	}
}

// trackedListResponse keeps body accounting independent of the production byte-budget logic.
func trackedListResponse(req *http.Request, padding int, knownLength bool) (*http.Response, *trackingBody) {
	kind := "PodList"
	if strings.Contains(req.URL.Path, "endpointslices") {
		kind = "EndpointSliceList"
	}
	raw := listJSON(kind, "", padding)
	body := &trackingBody{Reader: strings.NewReader(raw)}
	length := int64(-1)
	if knownLength {
		length = int64(len(raw))
	}
	return &http.Response{StatusCode: 200, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: body, ContentLength: length, Request: req}, body
}

// TestDiscoveryLimitsResponseBytesBeforeDecode checks the byte cap and body closure for both
// declared and unknown response lengths.
func TestDiscoveryLimitsResponseBytesBeforeDecode(t *testing.T) {
	for _, knownLength := range []bool{false, true} {
		t.Run(map[bool]string{false: "unknown-length", true: "declared-length"}[knownLength], func(t *testing.T) {
			f := newListResponseFixture(t, responseLimitForTest, knownLength)
			got, err := f.reader.Discover(t.Context())
			assertEmptyDiscovery(t, got, err, "oversized")
			bodies := f.bodies
			if len(bodies) != 1 || bodies[0].read > responseLimitForTest+1 || !bodies[0].closed {
				t.Fatalf("response not bounded/closed: %+v", bodies)
			}
		})
	}
}

// TestDiscoverySharesResponseBudgetAcrossCollections charges Pod and EndpointSlice bodies against
// one operation allowance.
func TestDiscoverySharesResponseBudgetAcrossCollections(t *testing.T) {
	f := newListResponseFixture(t, responseLimitForTest/2, false)
	got, err := f.reader.Discover(t.Context())
	assertEmptyDiscovery(t, got, err, "cumulative")
	bodies := f.bodies
	total := 0
	for _, body := range bodies {
		total += body.read
		if !body.closed {
			t.Fatal("unclosed response")
		}
	}
	if len(bodies) != 2 || total > responseLimitForTest+1 {
		t.Fatalf("unbounded collection responses: calls=%d bytes=%d", len(bodies), total)
	}
}

// TestDiscoveryRejectsAddressBudgetBeforeFetchingMorePages stops at the page that exhausts the
// cumulative address allowance.
func TestDiscoveryRejectsAddressBudgetBeforeFetchingMorePages(t *testing.T) {
	p := pod("allocator-a", "uid-a", "10.0.0.1")
	r, client := fixture(t, []corev1.Pod{p}, nil)
	calls := 0
	client.PrependReactor("list", "endpointslices", func(ktesting.Action) (bool, runtime.Object, error) {
		calls++
		s := endpointSlice("slice", p)
		s.Endpoints = make([]discoveryv1.Endpoint, 51)
		for i := range s.Endpoints {
			s.Endpoints[i] = endpointSlice("slice", p).Endpoints[0]
			s.Endpoints[i].Addresses = make([]string, 100)
			for j := range s.Endpoints[i].Addresses {
				s.Endpoints[i].Addresses[j] = p.Status.PodIP
			}
		}
		return true, &discoveryv1.EndpointSliceList{ListMeta: metav1.ListMeta{ResourceVersion: "rv", Continue: []string{"one", "two", ""}[calls-1]}, Items: []discoveryv1.EndpointSlice{s}}, nil
	})
	got, err := r.Discover(context.Background())
	if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) || calls != 2 {
		t.Fatalf("over-budget pages retained/fetched: calls=%d result=%+v error=%v", calls, got, err)
	}
}

// TestDiscoverySharesResponseBudgetAcrossPages prevents continuation responses from obtaining a
// fresh byte allowance.
func TestDiscoverySharesResponseBudgetAcrossPages(t *testing.T) {
	var bodies []*trackingBody
	transport := transportFunc(func(req *http.Request) (*http.Response, error) {
		cursor := "next"
		if req.URL.Query().Get("continue") != "" {
			cursor = ""
		}
		body := &trackingBody{Reader: strings.NewReader(listJSON("PodList", cursor, responseLimitForTest/2))}
		bodies = append(bodies, body)
		return jsonResponse(req, body), nil
	})
	r := readerFromRESTConfig(t, &rest.Config{Host: "https://api.example", Transport: transport, Timeout: time.Second})
	got, err := r.Discover(t.Context())
	if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) || len(bodies) != 2 {
		t.Fatalf("page budget bypass: calls=%d result=%+v error=%v", len(bodies), got, err)
	}
	if bodies[0].read+bodies[1].read > responseLimitForTest+1 || !bodies[0].closed || !bodies[1].closed {
		t.Fatal("page response budget or body ownership lost")
	}
}

// jsonResponse wraps an injected body as an unknown-length successful JSON response.
func jsonResponse(req *http.Request, body io.ReadCloser) *http.Response {
	return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": []string{"application/json"}}, Body: body, ContentLength: -1, Request: req}
}

// TestDiscoveryResponseBudgetRecoversAndIsIndependent gives later and concurrent operations fresh
// budgets after an oversized response.
func TestDiscoveryResponseBudgetRecoversAndIsIndependent(t *testing.T) {
	var mu sync.Mutex
	first := true
	transport := transportFunc(func(req *http.Request) (*http.Response, error) {
		mu.Lock()
		padding := responseLimitForTest / 3
		if first {
			padding = responseLimitForTest
			first = false
		}
		mu.Unlock()
		kind := "PodList"
		if strings.Contains(req.URL.Path, "endpointslices") {
			kind = "EndpointSliceList"
		}
		return jsonResponse(req, io.NopCloser(strings.NewReader(listJSON(kind, "", padding)))), nil
	})
	r := readerFromRESTConfig(t, &rest.Config{Host: "https://api.example", Transport: transport, Timeout: 5 * time.Second})
	if _, err := r.Discover(t.Context()); !errors.Is(err, ErrObservation) {
		t.Fatalf("first oversized response: %v", err)
	}
	var workers sync.WaitGroup
	for range 4 {
		workers.Go(func() {
			got, err := r.Discover(t.Context())
			if err != nil || got.PodResourceVersion != "rv" || got.EndpointSliceResourceVersion != "rv" {
				t.Errorf("fresh independent operation failed: %+v, %v", got, err)
			}
		})
	}
	workers.Wait()
}

// TestDiscoveryBoundsGzipExpansion charges decompressed JSON bytes while accepting compressed
// responses within the allowance.
func TestDiscoveryBoundsGzipExpansion(t *testing.T) {
	for _, oversized := range []bool{false, true} {
		t.Run(map[bool]string{false: "within-limit", true: "oversized"}[oversized], func(t *testing.T) {
			server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, req *http.Request) {
				kind := "PodList"
				if strings.Contains(req.URL.Path, "endpointslices") {
					kind = "EndpointSliceList"
				}
				padding := responseLimitForTest / 3
				if oversized {
					padding = responseLimitForTest
				}
				var compressed bytes.Buffer
				writer := gzip.NewWriter(&compressed)
				if _, err := io.WriteString(writer, listJSON(kind, "", padding)); err != nil {
					t.Error(err)
				}
				if err := writer.Close(); err != nil {
					t.Error(err)
				}
				w.Header().Set("Content-Type", "application/json")
				w.Header().Set("Content-Encoding", "gzip")
				if _, err := w.Write(compressed.Bytes()); err != nil {
					t.Error(err)
				}
			}))
			t.Cleanup(server.Close)
			r := readerFromRESTConfig(t, tlsRESTConfig(server, 5*time.Second))
			got, err := r.Discover(t.Context())
			if oversized {
				if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) {
					t.Fatalf("gzip expansion returned evidence: %+v, %v", got, err)
				}
			} else if err != nil || got.PodResourceVersion != "rv" || got.EndpointSliceResourceVersion != "rv" {
				t.Fatalf("bounded gzip response refused: %+v, %v", got, err)
			}
		})
	}
}

// TestObservePodBoundsResponsesAndRecovers rejects a one-byte overflow and then accepts an
// exact-limit response on the same reader.
func TestObservePodBoundsResponsesAndRecovers(t *testing.T) {
	p := pod("allocator-a", "uid-a", "10.0.0.1")
	p.TypeMeta = metav1.TypeMeta{APIVersion: "v1", Kind: "Pod"}
	encoded, err := json.Marshal(p)
	if err != nil {
		t.Fatal(err)
	}
	var bodies []*trackingBody
	transport := transportFunc(func(req *http.Request) (*http.Response, error) {
		raw := string(encoded)
		prefix := strings.TrimSuffix(raw, "}") + ",\"padding\":\""
		padding := responseLimitForTest - len(prefix) - len("\"}")
		if len(bodies) == 0 {
			padding++
		}
		raw = prefix + strings.Repeat("x", padding) + "\"}"
		body := &trackingBody{Reader: strings.NewReader(raw)}
		bodies = append(bodies, body)
		return jsonResponse(req, body), nil
	})
	r := readerFromRESTConfig(t, &rest.Config{Host: "https://api.example", Transport: transport, Timeout: time.Second})
	identity := Identity{p.Namespace, p.Name, string(p.UID)}
	got, err := r.ObservePod(t.Context(), identity)
	if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Observation{}) || len(bodies) != 1 || bodies[0].read > responseLimitForTest+1 || !bodies[0].closed {
		t.Fatalf("oversized Pod observation: %+v, %v", got, err)
	}
	got, err = r.ObservePod(t.Context(), identity)
	if err != nil || got.Presence != Present || got.Pod.Identity != identity || len(bodies) != 2 || !bodies[1].closed || bodies[1].read != responseLimitForTest {
		t.Fatalf("fresh Pod observation failed: %+v, %v", got, err)
	}
}

// TestDiscoveryChargesErrorResponsesBeforeRetry includes a retryable error body in the next
// request's remaining allowance.
func TestDiscoveryChargesErrorResponsesBeforeRetry(t *testing.T) {
	var bodies []*trackingBody
	transport := transportFunc(func(req *http.Request) (*http.Response, error) {
		body := &trackingBody{Reader: strings.NewReader(listJSON("PodList", "", responseLimitForTest/2))}
		bodies = append(bodies, body)
		response := jsonResponse(req, body)
		if len(bodies) == 1 {
			response.StatusCode = http.StatusTooManyRequests
			response.Header.Set("Retry-After", "1")
		}
		return response, nil
	})
	r := readerFromRESTConfig(t, &rest.Config{Host: "https://api.example", Transport: transport, Timeout: 5 * time.Second})
	got, err := r.Discover(t.Context())
	if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) || len(bodies) != 2 {
		t.Fatalf("retry bypassed cumulative budget: calls=%d result=%+v error=%v", len(bodies), got, err)
	}
	if bodies[0].read+bodies[1].read > responseLimitForTest+1 || !bodies[0].closed || !bodies[1].closed {
		t.Fatal("error-response bytes or body ownership lost")
	}
}

type failedReader struct{}

// Read injects a private body-read failure to exercise error sanitization and closure.
func (failedReader) Read([]byte) (int, error) { return 0, errors.New("private read failure") }

// TestDiscoveryClosesFailedAndUnresolvedEncodedBodies releases failed bodies and rejects
// unresolved encodings before reading their bytes.
func TestDiscoveryClosesFailedAndUnresolvedEncodedBodies(t *testing.T) {
	for _, encoded := range []bool{false, true} {
		t.Run(map[bool]string{false: "read-error", true: "unresolved-encoding"}[encoded], func(t *testing.T) {
			body := &trackingBody{Reader: io.MultiReader(strings.NewReader("data"), failedReader{})}
			transport := transportFunc(func(req *http.Request) (*http.Response, error) {
				response := jsonResponse(req, body)
				if encoded {
					response.Header.Set("Content-Encoding", "gzip")
				}
				return response, nil
			})
			r := readerFromRESTConfig(t, &rest.Config{Host: "https://api.example", Transport: transport, Timeout: time.Second})
			got, err := r.Discover(t.Context())
			if !errors.Is(err, ErrObservation) || !reflect.DeepEqual(got, Snapshot{}) || !body.closed {
				t.Fatalf("failed body leaked evidence or ownership: %+v, %v, closed=%v", got, err, body.closed)
			}
			wantRead := 4
			if encoded {
				wantRead = 0
			}
			if body.read != wantRead {
				t.Fatalf("unexpected read count: got %d want %d", body.read, wantRead)
			}
		})
	}
}

// TestDiscoveryConstructorRequiresBoundedRequests refuses missing, zero and negative per-request
// timeouts.
func TestDiscoveryConstructorRequiresBoundedRequests(t *testing.T) {
	for _, cfg := range []*rest.Config{nil, {Host: "https://api.example"}, {Host: "https://api.example", Timeout: -time.Second}} {
		if r, err := New(cfg, config()); !errors.Is(err, ErrInvalidArgument) || r != nil {
			t.Fatalf("unbounded request config accepted: %+v, %v", r, err)
		}
	}
}
