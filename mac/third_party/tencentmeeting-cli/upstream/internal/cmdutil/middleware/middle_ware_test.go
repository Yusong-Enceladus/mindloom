package middleware

import (
	"errors"
	"reflect"
	"testing"

	"github.com/spf13/cobra"
)

// makeRecordingMiddleware builds a middleware that appends the given labels
// to trace before and after calling next. This is used to verify the
// "onion model" execution order produced by Chain.
func makeRecordingMiddleware(trace *[]string, name string) CmdMiddleware {
	return func(next RunEFunc) RunEFunc {
		return func(cmd *cobra.Command, args []string) error {
			*trace = append(*trace, name+"-pre")
			if err := next(cmd, args); err != nil {
				return err
			}
			*trace = append(*trace, name+"-post")
			return nil
		}
	}
}

// Chain with no middleware should return a function that behaves exactly
// like the original RunE.
func TestChain_NoMiddleware(t *testing.T) {
	called := false
	run := func(cmd *cobra.Command, args []string) error {
		called = true
		return nil
	}

	wrapped := Chain(run)
	if err := wrapped(&cobra.Command{}, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !called {
		t.Fatal("expected the original RunE to be invoked")
	}
}

// A single middleware should wrap the RunE with pre/post hooks.
func TestChain_SingleMiddleware(t *testing.T) {
	var trace []string
	run := func(cmd *cobra.Command, args []string) error {
		trace = append(trace, "run")
		return nil
	}

	wrapped := Chain(run, makeRecordingMiddleware(&trace, "A"))
	if err := wrapped(&cobra.Command{}, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	want := []string{"A-pre", "run", "A-post"}
	if !reflect.DeepEqual(trace, want) {
		t.Fatalf("execution order mismatch, want %v got %v", want, trace)
	}
}

// Multiple middlewares must execute in the declared order for pre hooks and
// in reverse order for post hooks (onion model).
func TestChain_MultipleMiddlewareOrder(t *testing.T) {
	var trace []string
	run := func(cmd *cobra.Command, args []string) error {
		trace = append(trace, "run")
		return nil
	}

	wrapped := Chain(run,
		makeRecordingMiddleware(&trace, "A"),
		makeRecordingMiddleware(&trace, "B"),
		makeRecordingMiddleware(&trace, "C"),
	)
	if err := wrapped(&cobra.Command{}, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	want := []string{
		"A-pre", "B-pre", "C-pre",
		"run",
		"C-post", "B-post", "A-post",
	}
	if !reflect.DeepEqual(trace, want) {
		t.Fatalf("execution order mismatch, want %v got %v", want, trace)
	}
}

// When a middleware short-circuits (does not call next), downstream
// middlewares and the business RunE must not be executed.
func TestChain_MiddlewareShortCircuit(t *testing.T) {
	var trace []string
	run := func(cmd *cobra.Command, args []string) error {
		trace = append(trace, "run")
		return nil
	}

	shortCircuit := func(next RunEFunc) RunEFunc {
		return func(cmd *cobra.Command, args []string) error {
			trace = append(trace, "short")
			return nil
		}
	}

	wrapped := Chain(run,
		makeRecordingMiddleware(&trace, "A"),
		shortCircuit,
		makeRecordingMiddleware(&trace, "C"),
	)
	if err := wrapped(&cobra.Command{}, nil); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}

	want := []string{"A-pre", "short", "A-post"}
	if !reflect.DeepEqual(trace, want) {
		t.Fatalf("short-circuit order mismatch, want %v got %v", want, trace)
	}
}

// Errors returned from the business RunE must be propagated back through the
// chain to the caller.
func TestChain_RunErrorPropagates(t *testing.T) {
	wantErr := errors.New("boom")
	run := func(cmd *cobra.Command, args []string) error {
		return wantErr
	}

	wrapped := Chain(run,
		func(next RunEFunc) RunEFunc {
			return func(cmd *cobra.Command, args []string) error {
				return next(cmd, args)
			}
		},
	)

	if err := wrapped(&cobra.Command{}, nil); !errors.Is(err, wantErr) {
		t.Fatalf("expected %v, got %v", wantErr, err)
	}
}

// cmd and args passed to the wrapped RunE must be forwarded to the original
// business RunE unchanged.
func TestChain_ForwardsCmdAndArgs(t *testing.T) {
	inputCmd := &cobra.Command{Use: "demo"}
	inputArgs := []string{"a", "b"}

	var gotCmd *cobra.Command
	var gotArgs []string
	run := func(cmd *cobra.Command, args []string) error {
		gotCmd = cmd
		gotArgs = args
		return nil
	}

	wrapped := Chain(run,
		func(next RunEFunc) RunEFunc {
			return func(cmd *cobra.Command, args []string) error {
				return next(cmd, args)
			}
		},
	)

	if err := wrapped(inputCmd, inputArgs); err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if gotCmd != inputCmd {
		t.Fatalf("cmd not forwarded: got %p want %p", gotCmd, inputCmd)
	}
	if !reflect.DeepEqual(gotArgs, inputArgs) {
		t.Fatalf("args not forwarded: got %v want %v", gotArgs, inputArgs)
	}
}
