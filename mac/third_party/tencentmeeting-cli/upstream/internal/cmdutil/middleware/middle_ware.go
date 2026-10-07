package middleware

import (
	"github.com/spf13/cobra"
)

// RunEFunc is an alias for the cobra.Command.RunE function signature, which
// makes middleware composition more ergonomic.
type RunEFunc func(cmd *cobra.Command, args []string) error

// CmdMiddleware is a command-level middleware. It receives the next RunE in
// the chain and returns a wrapped RunE. Multiple middlewares are composed by
// Chain in an "onion" model: pre-logic runs in the order middlewares are
// passed in, and post-logic runs in the reverse order.
type CmdMiddleware func(next RunEFunc) RunEFunc

// Chain wraps a set of middlewares around the original RunE and returns the
// final function that can be assigned to cobra.Command.RunE. The input order
// is the same as the semantic execution order:
//
//	Chain(run, A, B, C) executes as
//	A-pre -> B-pre -> C-pre -> run -> C-post -> B-post -> A-post
//
// Note: the iteration below walks middlewares backwards so that the first
// middleware passed in ends up as the outermost layer.
func Chain(run RunEFunc, middlewares ...CmdMiddleware) RunEFunc {
	wrapped := run
	for i := len(middlewares) - 1; i >= 0; i-- {
		wrapped = middlewares[i](wrapped)
	}
	return wrapped
}
