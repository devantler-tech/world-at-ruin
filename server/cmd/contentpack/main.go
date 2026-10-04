// contentpack is an opt-in local operator command, absent from runtime composition.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"

	"github.com/devantler-tech/world-at-ruin/server/internal/contentpack"
)

// main reports local operator failures without joining runtime composition.
func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "contentpack:", err)
		os.Exit(1)
	}
}

// run requires explicit experimental admission before source or output I/O.
func run(args []string) error {
	flags := flag.NewFlagSet("contentpack", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	experimental := flags.Bool("experimental", false, "enable experimental local build tooling")
	operation := flags.String("operation", "", "stage, finalize or verify")
	source := flags.String("source", "", "trusted local Godot project")
	output := flags.String("output", "", "new final directory, or built directory for verification")
	work := flags.String("work", "", "private native staging directory")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return errors.New("invalid arguments")
	}
	if !*experimental {
		return errors.New("content packs are experimental; pass -experimental to opt in")
	}
	switch *operation {
	case "stage":
		if *source == "" || *work == "" {
			return errors.New("source and new staging directory are required")
		}
		return contentpack.Stage(*source, *work)
	case "finalize":
		if *source == "" || *work == "" || *output == "" {
			return errors.New("source, staging and new output directories are required")
		}
		return contentpack.Finalize(*source, *work, *output)
	case "verify":
		root, err := os.OpenRoot(*output)
		if err != nil {
			return errors.New("built evidence directory is unavailable")
		}
		pack, pErr := contentpack.ReadRegular(root, "content.pck", contentpack.MaxPackBytes)
		receipt, rErr := contentpack.ReadRegular(root, "receipt.json", 8<<20)
		inventory, iErr := contentpack.ReadRegular(root, "resources.json", 8<<20)
		closeErr := root.Close()
		if err := errors.Join(pErr, rErr, iErr, closeErr); err != nil {
			return err
		}
		var resources []contentpack.Resource
		if err := json.Unmarshal(inventory, &resources); err != nil {
			return err
		}
		return contentpack.Verify(pack, resources, receipt)
	default:
		return errors.New("unsupported operation")
	}
}
