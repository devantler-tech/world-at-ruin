//go:build war_native_trial && war_issued_trial && war_issued_spire && linux

package nakamatrial

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"maps"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
	"github.com/devantler-tech/world-at-ruin/server/testfixture/spire"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"golang.org/x/sys/unix"
)

const issuedServerURI = "spiffe://war-fixture.test/claims/private"
const issuedServerDNS = "claims.fixture.test"

var issuedRole = flag.String("war-spire-role", "", "private issued native worker")
var issuedAPI = flag.String("war-spire-api", "", "owned issuer socket")
var issuedPrivate = flag.String("war-spire-private", "", "issuer-private refusal control")
var issuedCut = flag.String("war-spire-cut", "", "private issued custody cut")
var issuedIdentity = flag.String("war-spire-id", "", "independent worker principal")

type issuedMessage struct {
	Case                                string
	Seq                                 uint64
	Op, ID, Token, DNS, URI, Credential string
	Binding                             agones.ClaimBinding
	Receipt                             zoneclaim.Receipt
	Accepted                            bool
}
type issuedChild struct {
	process *nativeProcess
	input   io.WriteCloser
	output  *os.File
	encoder *json.Encoder
	decoder *json.Decoder
	stopped bool
	closed  bool
}

func (c *issuedChild) exchange(t *testing.T, message issuedMessage) issuedMessage {
	t.Helper()
	if err := c.encoder.Encode(message); err != nil {
		t.Fatal("private worker command failed")
	}
	return c.read(t)
}
func (c *issuedChild) read(t *testing.T) issuedMessage {
	return c.readBefore(t, time.Now().Add(40*time.Second))
}

func (c *issuedChild) readBefore(t *testing.T, deadline time.Time) issuedMessage {
	t.Helper()
	if err := c.output.SetReadDeadline(deadline); err != nil {
		t.Fatal(err)
	}
	var reply issuedMessage
	if err := c.decoder.Decode(&reply); err != nil {
		t.Fatal("bounded private worker reply failed")
	}
	if reply.Op == "failed" {
		t.Fatalf("issued worker failed at bounded stage %s", reply.ID)
	}
	return reply
}

// Cleanup acknowledgement precedes an independently observed exact child wait.
func (c *issuedChild) close(t *testing.T) {
	t.Helper()
	if c.closed {
		return
	}
	c.closed = true
	_ = c.input.Close()
	var reply issuedMessage
	err := c.output.SetReadDeadline(time.Now().Add(30 * time.Second))
	if err == nil {
		err = c.decoder.Decode(&reply)
	}
	c.stopped = err == nil && reply.Op == "stopped"
	if !c.stopped {
		t.Error("native descendant cleanup unproved; retain containment")
	}
	if c.stopped {
		select {
		case <-c.process.done:
		case <-time.After(5 * time.Second):
			t.Error("acknowledged worker exceeded clean exit bound")
		}
	}
	c.process.stop(t)
	select {
	case <-c.process.done:
		if c.process.err != nil {
			t.Error("worker did not exit cleanly")
		}
	default:
		t.Error("worker join unknown")
	}
	_ = c.output.Close()
}
func issuedSecurity(t *testing.T, uid int, private string) {
	t.Helper()
	r, e, s := unix.Getresuid()
	if r != uid || e != uid || s != uid {
		t.Fatal("unexpected issued worker UID")
	}
	r, e, s = unix.Getresgid()
	if r != uid || e != uid || s != uid {
		t.Fatal("unexpected issued worker GID")
	}
	groups, err := os.Getgroups()
	if err != nil || uid != 0 && len(groups) != 0 {
		t.Fatal("issued process supplementary groups")
	}
	header := unix.CapUserHeader{Version: unix.LINUX_CAPABILITY_VERSION_3}
	var caps [2]unix.CapUserData
	if unix.Capget(&header, &caps[0]) != nil {
		t.Fatal("unreadable capability state")
	}
	expected := uint32(0)
	if uid == 0 {
		expected = 0xe0
	}
	if caps[0].Effective != expected || caps[0].Permitted != expected || caps[0].Inheritable != 0 || caps[1] != (unix.CapUserData{}) {
		t.Fatal("issued capability boundary changed")
	}
	nnp, err := unix.PrctlRetInt(unix.PR_GET_NO_NEW_PRIVS, 0, 0, 0, 0)
	if err != nil || nnp != 1 {
		t.Fatal("issued process lacks no-new-privileges")
	}
	for capability := uintptr(0); capability <= 40; capability++ {
		ambient, err := unix.PrctlRetInt(unix.PR_CAP_AMBIENT, unix.PR_CAP_AMBIENT_IS_SET, capability, 0, 0)
		if err != nil || ambient != 0 {
			t.Fatal("issued process ambient capability")
		}
	}
	if uid != 0 {
		file, err := os.Open(private)
		if err == nil {
			_ = file.Close()
			t.Fatal("worker opened issuer-private state")
		}
		if !errors.Is(err, os.ErrPermission) {
			t.Fatal("issuer-private refusal was not permission denied")
		}
	}
}
func TestNativeIssuedSPIRE(t *testing.T) {
	c := newIssuedController(t)
	ctx, runner, startWorker := c.ctx, c.runner, c.startWorker
	primary := spire.Start(t, ctx, c.directory, "primary", 18443, []spire.Entry{{ID: issuedServerURI, UID: 10001, DNS: issuedServerDNS}}, runner)
	alternate := spire.Start(t, ctx, c.directory, "alternate", 18444, nil, runner)

	coordinator := startWorker("coordinator", 10001, primary, issuedServerURI)
	handoff := coordinator.read(t)
	if handoff.Op != "handoff" || handoff.Token == "" || handoff.Binding.GameServerUID == "" {
		t.Fatal("actual native handoff missing")
	}
	principal := "spiffe://war-fixture.test/zone/" + handoff.Binding.Namespace + "/" + handoff.Binding.GameServerUID
	registrations := []spire.Entry{{ID: principal, UID: 10004}, {ID: principal + "-wrong", UID: 10003}, {ID: "spiffe://war-fixture.test/role/other", UID: 10002}}
	spire.Register(t, ctx, primary, registrations, runner)
	spire.Register(t, ctx, alternate, registrations[:1], runner)
	zone := startWorker("zone", 10004, primary, principal)
	wrong := startWorker("zone", 10003, primary, principal+"-wrong")
	role := startWorker("zone", 10002, primary, "spiffe://war-fixture.test/role/other")
	other := startWorker("zone", 10004, alternate, principal)
	for _, worker := range []*issuedChild{zone, wrong, role, other} {
		if worker.read(t).Op != "ready" {
			t.Fatal("issued worker not ready")
		}
	}
	claim := handoff
	claim.Op = "claim"
	claim.DNS = issuedServerDNS
	claim.URI = issuedServerURI
	for _, control := range []struct {
		worker        *issuedChild
		dns, uri, key string
	}{
		{wrong, issuedServerDNS, issuedServerURI, ""}, {role, issuedServerDNS, issuedServerURI, ""}, {other, issuedServerDNS, issuedServerURI, ""},
		{zone, "wrong.fixture.test", issuedServerURI, ""}, {zone, issuedServerDNS, issuedServerURI + "-wrong", ""},
		{zone, issuedServerDNS, issuedServerURI, "missing"}, {zone, issuedServerDNS, issuedServerURI, "mismatched"},
	} {
		request := claim
		request.DNS, request.URI, request.Credential = control.dns, control.uri, control.key
		if reply := control.worker.exchange(t, request); reply.Accepted || reply.Op != "claim" {
			t.Fatal("issued refusal accepted or incomplete")
		}
		if coordinator.exchange(t, issuedMessage{Op: "unchanged"}).Op != "unchanged" {
			t.Fatal("native refusal storage proof missing")
		}
	}
	positive := zone.exchange(t, claim)
	if !positive.Accepted || !positive.Receipt.Matches(handoff.Binding, 1) {
		t.Fatal("real issued native private claim failed")
	}
	positive.Op = "receipt"
	if coordinator.exchange(t, positive).Op != "receipt" {
		t.Fatal("independent native receipt proof missing")
	}
	replay := zone.exchange(t, claim)
	if !replay.Accepted || !replay.Receipt.Equal(positive.Receipt) {
		t.Fatal("issued replay receipt changed")
	}
	if coordinator.exchange(t, issuedMessage{Op: "unchanged"}).Op != "unchanged" {
		t.Fatal("replay changed native lease")
	}
	c.close(t)
	if t.Failed() {
		return
	}
	fmt.Println("ISSUED SPIRE NATIVE PASS: process-owned issuance; actual loaded plugin; exact allocation; verified TLS refusals; complete native receipt; unchanged replay; acknowledged descendant cleanup; exact joins")
}

// Replies use private FD3; ordinary stdout remains in controller-owned logs.
func TestNativeIssuedSPIREWorker(t *testing.T) {
	uid := 10001
	if *issuedRole == "zone" {
		uid = os.Getuid()
		if uid != 10002 && uid != 10003 && uid != 10004 {
			t.Fatal("unknown issued zone role")
		}
	} else if *issuedRole != "coordinator" && *issuedRole != "custody" {
		t.Fatal("unknown issued worker")
	}
	issuedSecurity(t, uid, *issuedPrivate)
	// This protocol writer belongs only to the worker, never its Nakama children.
	unix.CloseOnExec(3)
	output := os.NewFile(3, "private-issued-reply")
	if output == nil {
		t.Fatal("missing private response pipe")
	}
	encoder := json.NewEncoder(output)
	stage := "credential-readiness"
	defer func() {
		if t.Failed() {
			if err := encoder.Encode(issuedMessage{Op: "failed", ID: stage}); err != nil {
				t.Error("private failure reply failed")
			}
		}
		if err := output.Close(); err != nil {
			t.Error("private reply close failed")
		}
	}()
	// StartProcess passes blocking stdin descriptors. Make the owned worker
	// endpoint pollable before NewFile so read deadlines actually apply.
	if err := unix.SetNonblock(0, true); err != nil {
		t.Fatal("private input polling failed")
	}
	input := os.NewFile(0, "private-issued-input")
	defer func() {
		if err := input.Close(); err != nil {
			t.Error("private input close failed")
		}
	}()
	decoder := json.NewDecoder(input)
	send := func(message issuedMessage) {
		t.Helper()
		if err := encoder.Encode(message); err != nil {
			t.Fatal("private issued reply failed")
		}
	}
	receive := func() (issuedMessage, bool) {
		t.Helper()
		if err := input.SetReadDeadline(time.Now().Add(50 * time.Second)); err != nil {
			t.Fatal("private input deadline failed")
		}
		var message issuedMessage
		err := decoder.Decode(&message)
		if errors.Is(err, io.EOF) {
			return message, false
		}
		if err != nil {
			t.Fatal("private issued command failed")
		}
		return message, true
	}
	if *issuedRole == "custody" {
		stage = "original-custody"
		issuedCustodyWorker(t, input, encoder, decoder)
		if !t.Failed() {
			send(issuedMessage{Op: "stopped"})
		}
		return
	}
	material := issuedFetch(t, *issuedAPI, *issuedIdentity)
	if *issuedRole == "zone" {
		stage = "claim-exchange"
		send(issuedMessage{Op: "ready", ID: material.SVIDs[0].ID.String()})
		for {
			message, ok := receive()
			if !ok {
				break
			}
			if message.Op != "claim" {
				t.Fatal("unknown issued claim command")
			}
			receipt, err := issuedClaim(t, material, message)
			send(issuedMessage{Op: "claim", Case: message.Case, Seq: message.Seq, Accepted: err == nil, Receipt: receipt})
		}
	} else {
		if !t.Run("owned-native", func(t *testing.T) {
			stage = "native-fixture"
			f := newFixture(t)
			env := f.issuedClaimsEnv(*issuedAPI)
			env["WAR_HANDOFF_CLAIMS_TRUST_DOMAIN"] = "war-fixture.test"
			env["WAR_ISSUED_CLAIMS_SERVER_DNS"] = issuedServerDNS
			env["WAR_ISSUED_CLAIMS_SERVER_URI"] = issuedServerURI
			modules := filepath.Join(*bundle, "modules")
			for _, fault := range []string{"unavailable", "DNS", "URI"} {
				stage = "startup-refusal-" + fault
				bad := maps.Clone(env)
				switch fault {
				case "unavailable":
					bad["WAR_ISSUED_CLAIMS_SOCKET"] = filepath.Join(f.dir, "absent-api")
				case "DNS":
					bad["WAR_ISSUED_CLAIMS_SERVER_DNS"] = "wrong.fixture.test"
				case "URI":
					bad["WAR_ISSUED_CLAIMS_SERVER_URI"] = issuedServerURI + "-wrong"
				}
				p := f.launch(bad, modules, 10, false)
				reason := "issued claims WorkloadAPI request refused"
				switch fault {
				case "DNS":
					reason = "nakama handoff: configure private listener"
				case "URI":
					reason = "issued claims identity refused"
				}
				if p.err == nil || !strings.Contains(p.log.String(), reason) || strings.Contains(p.log.String(), "Go runtime modules loaded") {
					t.Fatal("issued startup refusal failed")
				}
				var count int
				ctx, cancel := context.WithTimeout(t.Context(), time.Second)
				err := f.db.QueryRowContext(ctx, "SELECT count(*) FROM storage WHERE collection=$1", collection).Scan(&count)
				cancel()
				if err != nil || count != 0 {
					t.Fatal("issued startup refusal changed native leases")
				}
			}
			stage = "native-plugin-readiness"
			p := f.launch(env, modules, 10, true)
			stage = "native-handoff"
			token, user := f.account("real-issued-native")
			handoff := f.handoff(token)
			gs := f.resource("zone-1")
			binding := agones.ClaimBinding{Namespace: "world-at-ruin", AllocationID: gs.Name, GameServerUID: string(gs.UID), LeaseObjectID: leaseKey(user), AttemptDigest: gs.Labels[agones.AttemptLabel]}
			value, version, _, _ := f.row(binding.LeaseObjectID)
			send(issuedMessage{Op: "handoff", Token: handoff.Token, Binding: binding})
			stage = "native-storage-observation"
			for {
				message, ok := receive()
				if !ok {
					break
				}
				current, currentVersion, read, write := f.row(binding.LeaseObjectID)
				switch message.Op {
				case "unchanged":
					if current != value || currentVersion != version {
						t.Fatal("refusal/replay mutated native storage")
					}
				case "receipt":
					var row map[string]json.RawMessage
					if json.Unmarshal([]byte(current), &row) != nil {
						t.Fatal("invalid native row")
					}
					var allocation, attempt string
					var observer uint64
					var claimed int64
					if json.Unmarshal(row["allocation_id"], &allocation) != nil || json.Unmarshal(row["attempt_id"], &attempt) != nil || json.Unmarshal(row["observer"], &observer) != nil || json.Unmarshal(row["claimed_at_nanos"], &claimed) != nil {
						t.Fatal("incomplete native row")
					}
					receipt := message.Receipt
					digest, err := agones.CorrelationLabel(attempt)
					if err != nil || currentVersion == version || read != 0 || write != 0 || !receipt.Matches(binding, 1) || receipt.Fence.LeaseVersion != currentVersion || observer != 1 || allocation != binding.AllocationID || digest != binding.AttemptDigest || claimed <= 0 || !receipt.Fence.Generation.Equal(time.Unix(0, claimed)) {
						t.Fatal("complete receipt disagrees with native SQL")
					}
					value, version = current, currentVersion
				default:
					t.Fatal("unknown native observation")
				}
				send(issuedMessage{Op: message.Op})
			}
			stage = "native-owned-shutdown"
			p.stop(t)
			connection, err := (&net.Dialer{Timeout: 100 * time.Millisecond}).DialContext(t.Context(), "tcp", "127.0.0.1:7443")
			if err == nil {
				_ = connection.Close()
				t.Fatal("issued listener survived owned shutdown")
			}
		}) {
			return
		}
	}
	if !t.Failed() {
		send(issuedMessage{Op: "stopped"})
	}
}
func issuedFetch(t *testing.T, socket, expected string) *workloadapi.X509Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Second)
	defer cancel()
	client, err := workloadapi.New(ctx, workloadapi.WithAddr("unix://"+socket))
	if err != nil {
		t.Fatal("issued WorkloadAPI client failed")
	}
	defer func() {
		if err := client.Close(); err != nil {
			t.Error("issued WorkloadAPI close failed")
		}
	}()
	for {
		request, stop := context.WithTimeout(ctx, time.Second)
		material, err := client.FetchX509Context(request)
		stop()
		if err == nil && material != nil && len(material.SVIDs) == 1 && material.SVIDs[0] != nil && material.SVIDs[0].ID.String() == expected && material.SVIDs[0].PrivateKey != nil {
			return material
		}
		select {
		case <-ctx.Done():
			t.Fatal("real role credential readiness failed")
		case <-time.After(100 * time.Millisecond):
		}
	}
}
func issuedClaim(t *testing.T, material *workloadapi.X509Context, message issuedMessage) (zoneclaim.Receipt, error) {
	t.Helper()
	svid := material.SVIDs[0]
	cert := tls.Certificate{PrivateKey: svid.PrivateKey, Leaf: svid.Certificates[0]}
	for _, certificate := range svid.Certificates {
		cert.Certificate = append(cert.Certificate, certificate.Raw)
	}
	bundle, err := material.Bundles.GetX509BundleForTrustDomain(svid.ID.TrustDomain())
	if err != nil {
		t.Fatal("issued trust bundle missing")
	}
	roots := x509.NewCertPool()
	for _, authority := range bundle.X509Authorities() {
		roots.AddCert(authority)
	}
	switch message.Credential {
	case "missing":
		cert = tls.Certificate{}
	case "mismatched":
		cert.PrivateKey, err = ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			t.Fatal(err)
		}
	}
	config := &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: roots, ServerName: message.DNS, VerifyConnection: func(state tls.ConnectionState) error {
		if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 || len(state.PeerCertificates[0].URIs) != 1 || state.PeerCertificates[0].URIs[0].String() != message.URI {
			return errors.New("unexpected verified server identity")
		}
		return nil
	}}
	if message.Credential != "missing" {
		config.Certificates = []tls.Certificate{cert}
	}
	client, err := claimrpc.NewClient("https://localhost:7443/v1/claim", config)
	if err != nil {
		return zoneclaim.Receipt{}, err
	}
	defer client.Close()
	ctx, cancel := context.WithTimeout(t.Context(), 3*time.Second)
	defer cancel()
	return client.ClaimWithReceipt(ctx, message.Binding, message.Token, 1)
}

// The controller alone owns issuer processes and cooperative worker retirement.
type issuedController struct {
	ctx         context.Context
	directory   string
	runner      spire.Runner
	startWorker func(string, uint32, spire.Issuer, string, ...string) *issuedChild
	processes   []*nativeProcess
	workers     []*issuedChild
}

func newIssuedController(t *testing.T) *issuedController {
	t.Helper()
	issuedSecurity(t, 0, "")
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	directory, err := os.MkdirTemp("/tmp", "war-issued-")
	if err != nil {
		t.Fatal(err)
	}
	if err = os.Chmod(directory, 0755); err != nil {
		t.Fatal(err)
	}
	c := &issuedController{ctx: ctx, directory: directory}
	t.Cleanup(func() {
		// Cooperate before canceling: coordinator owns a native grandchild.
		defer cancel()
		c.close(t)
		if t.Failed() {
			for i, p := range c.processes {
				if err := os.WriteFile(filepath.Join(directory, fmt.Sprintf("process-%d.log", i)), []byte(p.log.String()), 0600); err != nil {
					t.Error("private failure evidence retention failed")
				}
			}
			t.Log("retaining private issued evidence under disposable containment")
			return
		}
		if err := os.RemoveAll(directory); err != nil {
			t.Error(err)
		}
	})
	launch := func(cmd *exec.Cmd) *nativeProcess {
		p := &nativeProcess{cmd: cmd, done: make(chan struct{}), log: &lockedLog{}}
		cmd.Stdout, cmd.Stderr = p.log, p.log
		if err := cmd.Start(); err != nil {
			t.Fatal("owned issued process start failed")
		}
		c.processes = append(c.processes, p)
		go func() { p.err = cmd.Wait(); close(p.done) }()
		return p
	}
	runner := spire.Runner{Admin: func(request context.Context, args ...string) ([]byte, error) {
		return exec.CommandContext(request, "/opt/spire/bin/spire-server", args...).Output()
	}}
	runner.Launch = func(program spire.Program, config string) func() bool {
		var cmd *exec.Cmd
		switch program {
		case spire.Server:
			cmd = exec.CommandContext(ctx, "/opt/spire/bin/spire-server", "run", "-config", config)
		case spire.Agent:
			cmd = exec.CommandContext(ctx, "/opt/spire/bin/spire-agent", "run", "-config", config)
		default:
			t.Fatal("unknown issuer executable")
		}
		p := launch(cmd)
		return func() bool {
			select {
			case <-p.done:
				return true
			default:
				return false
			}
		}
	}
	startWorker := func(role string, uid uint32, issuer spire.Issuer, id string, cut ...string) *issuedChild {
		cmd := exec.CommandContext(ctx, "/out/native-trial.test", "-war-experimental", "-war-bundle="+*bundle, "-war-postgres="+*postgres, "-test.run=^TestNativeIssuedSPIREWorker$", "-test.timeout=4m", "-war-spire-role="+role, "-war-spire-api="+issuer.API, "-war-spire-private="+issuer.Private, "-war-spire-id="+id)
		if len(cut) != 0 {
			cmd.Args = append(cmd.Args, "-war-spire-cut="+cut[0])
		}
		cmd.SysProcAttr = &syscall.SysProcAttr{Credential: &syscall.Credential{Uid: uid, Gid: uid, Groups: []uint32{}}}
		password := "unused-claim-worker"
		if role == "coordinator" || role == "custody" {
			password = os.Getenv("WAR_NATIVE_DB_PASSWORD")
		}
		cmd.Env = []string{"WAR_NATIVE_DB_PASSWORD=" + password, "PATH=/usr/local/go/bin:/usr/bin:/bin", "NAKAMA_TELEMETRY=0"}
		input, err := cmd.StdinPipe()
		if err != nil {
			t.Fatal(err)
		}
		cmd.Cancel = input.Close
		cmd.WaitDelay = 25 * time.Second
		output, childOutput, err := os.Pipe()
		if err != nil {
			t.Fatal(err)
		}
		cmd.ExtraFiles = []*os.File{childOutput}
		p := launch(cmd)
		_ = childOutput.Close()
		child := &issuedChild{process: p, input: input, output: output, encoder: json.NewEncoder(input), decoder: json.NewDecoder(output)}
		c.workers = append(c.workers, child)
		return child
	}
	c.runner, c.startWorker = runner, startWorker
	return c
}

func (c *issuedController) close(t *testing.T) {
	t.Helper()
	for i := len(c.workers) - 1; i >= 0; i-- {
		c.workers[i].close(t)
	}
	for i := len(c.processes) - 1; i >= 0; i-- {
		c.processes[i].stop(t)
	}
}
