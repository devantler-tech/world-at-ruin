package nakamatrial

import (
	"bytes"
	"context"
	"errors"
	"io"
	"os/exec"
	"time"
)

const issuedReadinessMarker = "ISSUED CREDENTIAL PREREQUISITE READY"

// The owned helper's successful exit proves its SDK closed and its process joined.
// Its material never crosses this seam; only one complete fixed line is accepted.
func awaitIssuedReadinessProcess(ctx context.Context, prepare func(context.Context) *exec.Cmd) error {
	if ctx.Err() != nil {
		return errors.New("issued credential prerequisite lifetime refused")
	}
	command := prepare(ctx)
	command.Env = []string{"WAR_NATIVE_DB_PASSWORD=unused-readiness-worker", "PATH=/usr/local/go/bin:/usr/bin:/bin", "NAKAMA_TELEMETRY=0"}
	var output issuedReadinessOutput
	command.Stdout, command.Stderr = &output, io.Discard
	command.WaitDelay = time.Second
	if command.Run() != nil || ctx.Err() != nil {
		return errors.New("issued credential prerequisite incomplete")
	}
	count := 0
	for _, line := range bytes.SplitAfter(output.Bytes(), []byte{'\n'}) {
		if bytes.Equal(line, []byte(issuedReadinessMarker+"\n")) {
			count++
		}
	}
	if count != 1 {
		return errors.New("issued credential prerequisite verdict refused")
	}
	return nil
}

type issuedReadinessOutput struct{ bytes.Buffer }

// Write bounds private helper output before accepting any of its bytes.
func (output *issuedReadinessOutput) Write(data []byte) (int, error) {
	if len(data) > 64*1024-output.Len() {
		return 0, errors.New("issued credential prerequisite output bound reached")
	}
	return output.Buffer.Write(data)
}
