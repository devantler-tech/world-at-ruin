// MegaLinter's lychee 0.24.2 retries 429 but rejects 503/504 without retrying.
// Keep its extraction and exclusions; own one bounded budget per affected URL.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"html"
	"net/url"
	"os"
	"os/exec"
	"regexp"
	"strconv"
	"strings"
	"time"
)

type link struct {
	URL    string `json:"url"`
	Status struct {
		Code int    `json:"code"`
		Text string `json:"text"`
	} `json:"status"`
}

type report struct {
	Total       *int              `json:"total"`
	Unique      *int              `json:"unique"`
	Successful  *int              `json:"successful"`
	Errors      *int              `json:"errors"`
	Unknown     *int              `json:"unknown"`
	Unsupported *int              `json:"unsupported"`
	Timeouts    *int              `json:"timeouts"`
	Excludes    *int              `json:"excludes"`
	Detailed    *bool             `json:"detailed_stats"`
	ErrorMap    map[string][]link `json:"error_map"`
	SuccessMap  map[string][]link `json:"success_map"`
	TimeoutMap  map[string][]link `json:"timeout_map"`
	ExcludedMap map[string][]link `json:"excluded_map"`
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(2)
	}
}

func run(args []string) error {
	for _, arg := range args {
		switch arg {
		case "--help", "-h", "--version", "-V", "--dump":
			cmd := exec.Command("lychee", args...)
			cmd.Stdin, cmd.Stdout, cmd.Stderr = os.Stdin, os.Stdout, os.Stderr
			return cmd.Run()
		}
	}
	options, inputs, config, err := arguments(args)
	if err != nil {
		return err
	}
	budget, err := retryBudget(config)
	if err != nil {
		return err
	}
	options = append(options, "--max-retries", "0")
	input, err := extract(options, inputs)
	if err != nil {
		return err
	}
	defer os.Remove(input)
	// Dump has already applied CLI remaps; do not apply them a second time.
	var checkOptions []string
	for i := 0; i < len(options); i++ {
		if options[i] == "--remap" {
			i++
			continue
		}
		checkOptions = append(checkOptions, options[i])
	}
	options = checkOptions
	result, err := check(options, []string{input})
	if err != nil {
		return err
	}
	// Native retries are disabled in every pass: transitions between 429 and
	// 503/504 must share one budget, including duplicate citations across files.
	recovered := make(map[string]bool)
	processed := make(map[string]link)
	for source, links := range result.ErrorMap {
		for i := range links {
			entry := &links[i]
			if previous, ok := processed[entry.URL]; ok {
				entry.Status = previous.Status
				continue
			}
			if !retryable(entry.Status.Code) {
				continue
			}
			input, err := retryInput(entry.URL)
			if err != nil {
				return err
			}
			for attempt := 0; attempt < budget; attempt++ {
				time.Sleep(time.Second << attempt)
				next, err := check(options, []string{input})
				if err != nil {
					os.Remove(input)
					return err
				}
				if *next.Total != 1 || *next.Unique != 1 || *next.Unknown != 0 || *next.Unsupported != 0 || *next.Timeouts != 0 || *next.Excludes != 0 {
					os.Remove(input)
					return fmt.Errorf("incomplete retry observation for %s", entry.URL)
				}
				if *next.Successful == 1 && *next.Errors == 0 {
					for _, successes := range next.SuccessMap {
						if len(successes) != 1 || successes[0].URL != entry.URL {
							os.Remove(input)
							return fmt.Errorf("retry success did not name the requested URL")
						}
					}
					recovered[entry.URL] = true
					break
				}
				failures := 0
				for _, values := range next.ErrorMap {
					for _, value := range values {
						if value.URL != entry.URL {
							os.Remove(input)
							return fmt.Errorf("retry reported an unexpected URL: %s", value.URL)
						}
						entry.Status = value.Status
						failures++
					}
				}
				if *next.Errors != 1 || failures != 1 {
					os.Remove(input)
					return fmt.Errorf("incomplete retry failure for %s", entry.URL)
				}
				if !retryable(entry.Status.Code) {
					break
				}
			}
			os.Remove(input)
			processed[entry.URL] = *entry
		}
		result.ErrorMap[source] = links
	}
	fmt.Printf("Checked %d unique links; recovered %d temporary HTTP errors\n", *result.Unique, len(recovered))
	remaining := *result.Errors - len(recovered)
	if remaining < 0 {
		return fmt.Errorf("inconsistent error accounting")
	}
	fmt.Printf("Errors............%d\n", remaining+*result.Timeouts+*result.Unknown)
	fmt.Printf("Unsupported.......%d\n", *result.Unsupported)
	if remaining != 0 || *result.Timeouts != 0 || *result.Unknown != 0 {
		fmt.Printf("Documentation inputs: %s\n", strings.Join(inputs, ", "))
	}
	for _, links := range result.ErrorMap {
		for _, entry := range links {
			if !recovered[entry.URL] {
				fmt.Printf("[%d] %s | %s\n", entry.Status.Code, entry.URL, entry.Status.Text)
			}
		}
	}
	for _, links := range result.TimeoutMap {
		for _, entry := range links {
			fmt.Printf("[timeout] %s | %s\n", entry.URL, entry.Status.Text)
		}
	}
	if *result.Unknown != 0 {
		fmt.Printf("Unknown...........%d\n", *result.Unknown)
	}
	if remaining != 0 || *result.Unknown != 0 || *result.Timeouts != 0 {
		return fmt.Errorf("documentation links failed validation")
	}
	return nil
}

// Native extraction sees every original input and applies the production
// exclusions/remaps. Deduplicate before HTTP checks so repeated citations never
// spend the same URL's first attempt more than once.
func extract(options, inputs []string) (string, error) {
	args := append(append(append([]string(nil), options...), "--dump", "--"), inputs...)
	cmd := exec.Command("lychee", args...)
	var diagnostics bytes.Buffer
	cmd.Stderr = &diagnostics
	output, err := cmd.Output()
	if err != nil || diagnostics.Len() != 0 {
		return "", fmt.Errorf("documentation extraction was not clean: %v\n%s", err, diagnostics.String())
	}
	seen := make(map[string]bool)
	var content strings.Builder
	for _, target := range strings.Split(strings.TrimSpace(string(output)), "\n") {
		if target == "" || seen[target] {
			continue
		}
		u, err := url.Parse(target)
		if err != nil || u.Scheme == "" || strings.ContainsAny(target, "\r\n<>") {
			return "", fmt.Errorf("invalid extracted URL")
		}
		seen[target] = true
		fmt.Fprintf(&content, "[Documentation link](<%s>)\n", html.EscapeString(target))
	}
	file, err := os.CreateTemp("", "war-lychee-inputs-*.md")
	if err != nil {
		return "", err
	}
	_, writeErr := file.WriteString(content.String())
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		os.Remove(file.Name())
		return "", fmt.Errorf("cannot write extracted inputs: %v %v", writeErr, closeErr)
	}
	return file.Name(), nil
}

func retryable(status int) bool {
	switch status {
	case 429, 503, 504:
		return true
	default:
		return false
	}
}

// A URL CLI input tells lychee to fetch that document and extract its links.
// A local Markdown citation instead rechecks the failed URL itself, once.
func retryInput(target string) (string, error) {
	u, err := url.Parse(target)
	if err != nil {
		return "", fmt.Errorf("invalid retry URL")
	}
	switch u.Scheme {
	case "http", "https":
	default:
		return "", fmt.Errorf("invalid retry URL")
	}
	if u.Host == "" || strings.ContainsAny(target, "\r\n<>") {
		return "", fmt.Errorf("invalid retry URL")
	}
	file, err := os.CreateTemp("", "war-lychee-retry-*.md")
	if err != nil {
		return "", err
	}
	_, writeErr := fmt.Fprintf(file, "[Retry](<%s>)\n", html.EscapeString(target))
	closeErr := file.Close()
	if writeErr != nil || closeErr != nil {
		os.Remove(file.Name())
		return "", fmt.Errorf("cannot write retry input: %v %v", writeErr, closeErr)
	}
	return file.Name(), nil
}

// MegaLinter supplies options followed by a list of files. Keep all options
// (including exclusions, remaps and host config), replacing only format.
func arguments(args []string) (options, inputs []string, config string, err error) {
	valueOptions := "|--config|-c|--format|-f|--timeout|-t|--max-retries|--retry-wait-time|-r|--remap|--exclude|--include|--exclude-path|--user-agent|--max-concurrency|--root-dir|--base|--accept|-a|"
	config = "lychee.toml"
	for i := 0; i < len(args); i++ {
		arg := args[i]
		if arg == "--" {
			inputs = append(inputs, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(arg, "-") {
			inputs = append(inputs, arg)
			continue
		}
		name, value, equals := strings.Cut(arg, "=")
		if strings.Contains(valueOptions, "|"+name+"|") {
			if !equals {
				i++
				if i == len(args) {
					return nil, nil, "", fmt.Errorf("missing value for %s", name)
				}
				value = args[i]
			}
			switch name {
			case "--format", "-f":
				if value != "detailed" {
					return nil, nil, "", fmt.Errorf("the MegaLinter adapter requires detailed format")
				}
				continue
			case "--config", "-c":
				config = value
			case "--max-retries", "--retry-wait-time", "-r":
				return nil, nil, "", fmt.Errorf("retry policy must come from lychee.toml")
			}
			options = append(options, name, value)
		} else {
			switch name {
			case "--output", "-o":
				return nil, nil, "", fmt.Errorf("file output is unsupported by the MegaLinter adapter")
			}
			options = append(options, arg)
		}
	}
	if len(inputs) == 0 {
		return nil, nil, "", fmt.Errorf("documentation inputs are required")
	}
	return append(options, "--format", "json"), inputs, config, nil
}

func retryBudget(config string) (int, error) {
	data, err := os.ReadFile(config)
	if err != nil {
		return 0, err
	}
	if regexp.MustCompile(`(?m)^\s*remap\s*=`).Match(data) {
		return 0, fmt.Errorf("use CLI remaps; configuration remaps cannot be applied twice")
	}
	// The production policy has a top-level integer budget. Refuse missing,
	// ambiguous or unbounded values instead of inventing a fallback policy.
	matches := regexp.MustCompile(`(?m)^max_retries\s*=\s*([0-9]+)\s*(?:#.*)?$`).FindAllStringSubmatch(string(data), -1)
	if len(matches) != 1 {
		return 0, fmt.Errorf("one explicit max_retries policy is required")
	}
	budget, err := strconv.Atoi(matches[0][1])
	if err != nil || budget < 0 || budget > 5 {
		return 0, fmt.Errorf("retry budget must be between zero and five")
	}
	return budget, nil
}

func check(options, inputs []string) (report, error) {
	args := append(append(append([]string(nil), options...), "--verbose", "--"), inputs...)
	cmd := exec.Command("lychee", args...)
	cmd.Stderr = os.Stderr
	output, err := cmd.Output()
	if err != nil {
		if exit, ok := err.(*exec.ExitError); !ok || exit.ExitCode() != 2 {
			return report{}, fmt.Errorf("lychee could not validate inputs: %w", err)
		}
	}
	var result report
	if json.Unmarshal(output, &result) != nil || result.Total == nil || result.Unique == nil || result.Successful == nil || result.Errors == nil || result.Unknown == nil || result.Unsupported == nil || result.Timeouts == nil || result.Excludes == nil || result.ErrorMap == nil || result.SuccessMap == nil || result.TimeoutMap == nil || result.ExcludedMap == nil || result.Detailed == nil || !*result.Detailed {
		return report{}, fmt.Errorf("lychee returned a malformed or incomplete report")
	}
	for _, value := range []*int{result.Total, result.Unique, result.Successful, result.Errors, result.Unknown, result.Unsupported, result.Timeouts, result.Excludes} {
		if *value < 0 {
			return report{}, fmt.Errorf("negative observation count")
		}
	}
	count := func(values map[string][]link) int {
		total := 0
		for _, entries := range values {
			for _, entry := range entries {
				if entry.URL == "" || entry.Status.Text == "" {
					return -1
				}
				total++
			}
		}
		return total
	}
	if *result.Total < *result.Unique || *result.Total != *result.Successful+*result.Errors+*result.Unknown+*result.Unsupported+*result.Timeouts+*result.Excludes || count(result.ErrorMap) != *result.Errors || count(result.SuccessMap) != *result.Successful || count(result.TimeoutMap) != *result.Timeouts || count(result.ExcludedMap) != *result.Excludes {
		return report{}, fmt.Errorf("incomplete observation accounting")
	}
	if (err == nil) != (*result.Errors == 0 && *result.Unknown == 0 && *result.Timeouts == 0) {
		return report{}, fmt.Errorf("lychee exit status disagrees with its report")
	}
	return result, nil
}
