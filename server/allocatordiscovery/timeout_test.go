package allocatordiscovery

import (
	"context"
	"errors"
	"io"
	"net/http"
	"reflect"
	"strings"
	"testing"
	"testing/synctest"
	"time"

	"k8s.io/client-go/rest"
)

type requestTimeoutBody struct {
	ctx context.Context
	eof bool
}

// Read models a connection error after the request deadline interrupts a body read.
func (b requestTimeoutBody) Read([]byte) (int, error) {
	<-b.ctx.Done()
	if b.eof {
		return 0, io.EOF
	}
	return 0, errors.New("private connection read failure")
}

// TestBoundedTransportPreservesRequestDeadline covers the error before net/http
// can optionally wrap it. A request timer can close a connection with an error
// that does not itself wrap DeadlineExceeded.
func TestBoundedTransportPreservesRequestDeadline(t *testing.T) {
	for _, stage := range []string{"headers", "body", "body-eof"} {
		t.Run(stage, func(t *testing.T) {
			synctest.Test(t, func(t *testing.T) {
				ctx, cancel := context.WithTimeout(withResponseBudget(t.Context()), time.Hour)
				defer cancel()
				req, err := http.NewRequestWithContext(ctx, http.MethodGet, "https://api.example", nil)
				if err != nil {
					t.Fatal(err)
				}
				var body *trackingBody
				transport := boundedTransport{next: transportFunc(func(req *http.Request) (*http.Response, error) {
					if stage == "headers" {
						<-req.Context().Done()
						return nil, errors.New("private connection header failure")
					}
					body = &trackingBody{Reader: requestTimeoutBody{ctx: req.Context(), eof: stage == "body-eof"}}
					return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: body}, nil
				})}
				response, err := transport.RoundTrip(req)
				if response != nil {
					if closeErr := response.Body.Close(); closeErr != nil {
						t.Error(closeErr)
					}
				}
				if response != nil || !errors.Is(err, context.DeadlineExceeded) {
					t.Fatalf("request deadline lost at %s: response=%v err=%v", stage, response, err)
				}
				if stage != "headers" && (body == nil || !body.closed) {
					t.Fatal("timed out response body was not closed")
				}
			})
		})
	}
}

// TestRequestTimeoutClassification reaches both reads with the real generated clients.
// Fake time expires only after the selected read blocks, so TLS setup and scheduling
// cannot accidentally turn the body case into a header timeout.
func TestRequestTimeoutClassification(t *testing.T) {
	for _, stage := range []string{"headers", "body", "body-eof", "malformed"} {
		for _, operation := range []string{"discover", "observe"} {
			t.Run(operation+"/"+stage, func(t *testing.T) {
				synctest.Test(t, func(t *testing.T) {
					var body *trackingBody
					calls := 0
					transport := transportFunc(func(req *http.Request) (*http.Response, error) {
						calls++
						if stage == "headers" {
							<-req.Context().Done()
							return nil, errors.New("private connection header failure")
						}
						var source io.Reader = strings.NewReader("not JSON")
						if stage == "body" || stage == "body-eof" {
							source = io.MultiReader(strings.NewReader("{"), requestTimeoutBody{ctx: req.Context(), eof: stage == "body-eof"})
						}
						body = &trackingBody{Reader: source}
						return &http.Response{StatusCode: http.StatusOK, Header: http.Header{"Content-Type": {"application/json"}}, Body: body}, nil
					})
					reader := readerFromRESTConfig(t, &rest.Config{Host: "https://api.example", Transport: transport, Timeout: time.Hour})
					var err error
					if operation == "discover" {
						var got Snapshot
						got, err = reader.Discover(t.Context())
						if !reflect.DeepEqual(got, Snapshot{}) {
							t.Fatalf("failed discovery returned partial data: %+v", got)
						}
					} else {
						var got Observation
						got, err = reader.ObservePod(t.Context(), Identity{Namespace: "allocation", Name: "allocator-a", UID: "uid-a"})
						if !reflect.DeepEqual(got, Observation{}) {
							t.Fatalf("failed read returned an observation: %+v", got)
						}
					}
					want := context.DeadlineExceeded
					if stage == "malformed" {
						want = ErrObservation
					}
					if !errors.Is(err, want) {
						t.Fatalf("wrong failure classification: got %v, want %v", err, want)
					}
					if t.Context().Err() != nil || calls != 1 {
						t.Fatalf("request deadline leaked to caller or issued extra reads: caller=%v calls=%d", t.Context().Err(), calls)
					}
					if stage != "headers" && (body == nil || !body.closed) {
						t.Fatal("response body was not closed")
					}
				})
			})
		}
	}
}
