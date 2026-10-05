// Command nakama-runtime-build constructs an explicitly experimental native bundle.
package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
)

// execute refuses implicit builds and existing artifacts before touching output.
func execute(ctx context.Context, args []string, out io.Writer) error {
	flags := flag.NewFlagSet("nakama-runtime-build", flag.ContinueOnError)
	flags.SetOutput(out)
	experimental := flags.Bool("experimental", false, "explicitly build the disposable native trial bundle")
	source := flags.String("source", "server", "server source directory")
	output := flags.String("output", "", "new, absent bundle directory")
	if err := flags.Parse(args); err != nil {
		return err
	}
	if !*experimental {
		return errors.New("native Nakama build requires -experimental")
	}
	if *output == "" || flags.NArg() != 0 {
		return errors.New("native Nakama build requires an absent -output directory")
	}
	if _, err := os.Lstat(*output); !errors.Is(err, os.ErrNotExist) {
		return errors.New("native Nakama build output must be absent")
	}
	for _, name := range []string{"nakama-runtime.mod", "nakama-runtime.sum"} {
		if info, err := os.Stat(filepath.Join(*source, name)); err != nil || !info.Mode().IsRegular() {
			return errors.New("native Nakama build locked graph unavailable")
		}
	}
	return build(ctx, *source, *output, out)
}

// main reports refusals and build failures as unsuccessful command execution.
func main() {
	if err := execute(context.Background(), os.Args[1:], os.Stderr); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
