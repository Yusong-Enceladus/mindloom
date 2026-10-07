package cmdutil

import "github.com/spf13/cobra"

// ApiCmdResolver decides which ApiCmd this invocation corresponds to,
// based on the parsed cobra.Command state (flags/args).
//
// Returning an empty string means "no ApiCmd for this invocation"; downstream
// middlewares (e.g. WithCompact) will skip gracefully in that case.
type ApiCmdResolver interface {
	Resolve(cmd *cobra.Command) string
}

// --- 1. Static resolver: a command maps to a single fixed ApiCmd ---

type staticResolver string

// Resolve implements ApiCmdResolver.
func (s staticResolver) Resolve(_ *cobra.Command) string { return string(s) }

// StaticApiCmd builds a resolver for commands that always map to one ApiCmd.
func StaticApiCmd(name string) ApiCmdResolver { return staticResolver(name) }

// --- 2. Flag-based switch resolver: ordered, first-match-wins ---

// FlagCase declares a single routing rule. When When(cmd) returns true, the
// ApiCmd on this case is selected and no subsequent cases are evaluated.
//
// Because evaluation is ordered and short-circuited, callers should list
// higher-priority / more-specific cases first.
type FlagCase struct {
	When   func(cmd *cobra.Command) bool
	ApiCmd string
}

type flagSwitchResolver struct {
	cases    []FlagCase
	fallback string
}

// Resolve evaluates cases in declaration order and returns the ApiCmd of the
// first case whose When predicate returns true. Remaining predicates are NOT
// invoked (short-circuit). If no case matches, the fallback (possibly empty)
// is returned.
func (f flagSwitchResolver) Resolve(cmd *cobra.Command) string {
	for _, c := range f.cases {
		if c.When != nil && c.When(cmd) {
			return c.ApiCmd
		}
	}
	return f.fallback
}

// FlagSwitch declares an ordered list of Flag->ApiCmd routing rules.
//
// Semantics:
//   - Cases are evaluated strictly in the order they are passed in.
//   - The first case whose When predicate returns true wins; later cases'
//     predicates will NOT be evaluated.
//   - If no case matches, the resolver returns "" (meaning "no ApiCmd").
//
// List higher-priority / more-specific cases first.
func FlagSwitch(cases ...FlagCase) ApiCmdResolver {
	return flagSwitchResolver{cases: cases}
}

// FlagSwitchWithDefault behaves exactly like FlagSwitch (ordered, first-match-wins,
// short-circuit evaluation) but falls back to defaultApiCmd when no case matches.
func FlagSwitchWithDefault(defaultApiCmd string, cases ...FlagCase) ApiCmdResolver {
	return flagSwitchResolver{cases: cases, fallback: defaultApiCmd}
}

// --- 3. Common predicates used by FlagCase.When ---

// WhenStringFlagSet returns a predicate that checks whether a string flag is
// present and non-empty on the given command.
func WhenStringFlagSet(flagName string) func(cmd *cobra.Command) bool {
	return func(cmd *cobra.Command) bool {
		v, err := cmd.Flags().GetString(flagName)
		if err != nil {
			return false
		}
		return v != ""
	}
}

// --- 4. Escape hatch: build a resolver from an arbitrary function ---

type funcResolver func(cmd *cobra.Command) string

// Resolve implements ApiCmdResolver.
func (f funcResolver) Resolve(cmd *cobra.Command) string { return f(cmd) }

// ResolverFunc adapts a plain function into an ApiCmdResolver.
func ResolverFunc(fn func(cmd *cobra.Command) string) ApiCmdResolver {
	return funcResolver(fn)
}
