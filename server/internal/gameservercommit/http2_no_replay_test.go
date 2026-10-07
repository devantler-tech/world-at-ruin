package gameservercommit

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"net/http/httptest"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"golang.org/x/net/http2"
	"golang.org/x/net/http2/hpack"
	"k8s.io/client-go/rest"
)

// This is a real TLS/HTTP2 peer. It receives the entire PUT, then says the
// stream was unprocessed using the two standard retry signals. Neither signal
// may cause a second frozen HTTP PUT for this capability.
func TestNoStandardHTTP2MutationReplay(t *testing.T) {
	for _, mode := range []string{"refused-stream", "unprocessed-goaway"} {
		t.Run(mode, func(t *testing.T) {
			var puts atomic.Int32
			var bodyMu sync.Mutex
			var firstBody []byte
			var sameFrozenBody bool
			s := httptest.NewUnstartedServer(http.HandlerFunc(func(http.ResponseWriter, *http.Request) {
				t.Error("unexpected HTTP/1 request")
			}))
			s.EnableHTTP2 = true
			s.Config.TLSNextProto = map[string]func(*http.Server, *tls.Conn, http.Handler){
				"h2": func(_ *http.Server, c *tls.Conn, _ http.Handler) {
					defer func() { _ = c.Close() }()
					_ = c.SetDeadline(time.Now().Add(5 * time.Second))
					preface := make([]byte, len(http2.ClientPreface))
					if _, err := io.ReadFull(c, preface); err != nil {
						return
					}
					if string(preface) != http2.ClientPreface {
						t.Error("invalid HTTP/2 preface")
						return
					}
					fr := http2.NewFramer(c, c)
					fr.ReadMetaHeaders = hpack.NewDecoder(4096, nil)
					if err := fr.WriteSettings(); err != nil {
						return
					}
					type stream struct {
						method string
						body   []byte
					}
					streams := map[uint32]*stream{}
					finish := func(id uint32, st *stream) error {
						obj := ready()
						if st.method == http.MethodPut {
							n := puts.Add(1)
							bodyMu.Lock()
							if n == 1 {
								firstBody = append([]byte(nil), st.body...)
							} else {
								sameFrozenBody = bytes.Equal(firstBody, st.body)
							}
							bodyMu.Unlock()
							if n == 1 {
								if mode == "refused-stream" {
									return fr.WriteRSTStream(id, http2.ErrCodeRefusedStream)
								}
								return fr.WriteGoAway(id-2, http2.ErrCodeNo, nil)
							}
							if err := json.Unmarshal(st.body, obj); err != nil {
								return err
							}
							obj.ResourceVersion = "opaque-b"
						}
						data, err := json.Marshal(obj)
						if err != nil {
							return err
						}
						var block bytes.Buffer
						enc := hpack.NewEncoder(&block)
						if err = enc.WriteField(hpack.HeaderField{Name: ":status", Value: "200"}); err != nil {
							return err
						}
						if err = enc.WriteField(hpack.HeaderField{Name: "content-type", Value: "application/json"}); err != nil {
							return err
						}
						if err = fr.WriteHeaders(http2.HeadersFrameParam{StreamID: id, BlockFragment: block.Bytes(), EndHeaders: true}); err != nil {
							return err
						}
						return fr.WriteData(id, true, data)
					}
					for {
						f, err := fr.ReadFrame()
						if err != nil {
							return
						}
						switch f := f.(type) {
						case *http2.SettingsFrame:
							if !f.IsAck() {
								if err = fr.WriteSettingsAck(); err != nil {
									return
								}
							}
						case *http2.MetaHeadersFrame:
							st := &stream{}
							for _, field := range f.Fields {
								if field.Name == ":method" {
									st.method = field.Value
								}
							}
							streams[f.StreamID] = st
							if f.StreamEnded() {
								if err = finish(f.StreamID, st); err != nil {
									t.Error(err)
									return
								}
							}
						case *http2.DataFrame:
							st := streams[f.StreamID]
							if st == nil {
								t.Error("missing request headers")
								return
							}
							st.body = append(st.body, f.Data()...)
							if f.StreamEnded() {
								if err = finish(f.StreamID, st); err != nil {
									t.Error(err)
									return
								}
							}
						case *http2.PingFrame:
							if !f.Flags.Has(http2.FlagPingAck) {
								if err = fr.WritePing(true, f.Data); err != nil {
									return
								}
							}
						}
					}
				},
			}
			s.StartTLS()
			defer func() { _ = s.Config.Close(); s.Close() }()
			c, err := New(Config{Enabled: true, REST: &rest.Config{Host: s.URL, TLSClientConfig: rest.TLSClientConfig{Insecure: true}, Timeout: 2 * time.Second}, Namespace: "trial", Fleet: "fleet"})
			if err != nil {
				t.Fatal(err)
			}
			g, err := c.Prepare(context.Background(), "zone", "attempt-1")
			if err != nil {
				t.Fatal(err)
			}
			err = g.Commit(context.Background())
			bodyMu.Lock()
			same := sameFrozenBody
			bodyMu.Unlock()
			t.Logf("mode=%s PUTs=%d same_frozen_body=%t commit=%v", mode, puts.Load(), same, err)
			if puts.Load() != 1 {
				t.Errorf("hidden standard HTTP/2 replay: %d PUTs", puts.Load())
			}
			if !errors.Is(err, ErrUnknown) {
				t.Errorf("want ErrUnknown after first refusal, got %v", err)
			}
			if err = g.Commit(context.Background()); !errors.Is(err, ErrClosed) {
				t.Errorf("reopened capability: %v", err)
			}
		})
	}
}
