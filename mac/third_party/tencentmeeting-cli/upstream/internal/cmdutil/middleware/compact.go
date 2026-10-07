package middleware

import (
	"context"
	"tmeet/internal/cmdutil"
	"tmeet/internal/log"

	"github.com/spf13/cobra"

	"tmeet/internal"
)

// compactCtxKey is the unexported key type used to stash the remotely-fetched
// compact field list into a cobra command's context.
type compactCtxKey struct{}

// CompactFieldsKey is the context key used to read/write the compact field
// list on cmd.Context().
var CompactFieldsKey = compactCtxKey{}

// WithCompact returns a middleware that, when the --compact flag is true,
// fetches the compact field list for the current command from the remote end
// before the business RunE runs and stores it into cmd.Context(). The
// business RunE can then read the list via ctx.Value(CompactFieldsKey) and
// feed it into output.WithCompact.
//
// When --compact is false or the remote fetch fails, the middleware passes
// through transparently so that the main flow is never blocked by a compact
// concern.
func WithCompact(tmeet *internal.Tmeet) CmdMiddleware {
	return func(next RunEFunc) RunEFunc {
		return func(cmd *cobra.Command, args []string) error {
			compact, _ := cmd.Root().PersistentFlags().GetBool("compact")
			if !compact {
				return next(cmd, args)
			}

			fields, err := fetchCompactFields(cmd, tmeet)
			if err != nil {
				// A remote failure must not block the main flow; just skip
				// the compact trimming for this invocation.
				return next(cmd, args)
			}

			ctx := context.WithValue(cmd.Context(), CompactFieldsKey, fields)
			cmd.SetContext(ctx)
			return next(cmd, args)
		}
	}
}

// fetchCompactFields is the extension point for fetching the compact field list
func fetchCompactFields(cmd *cobra.Command, tmeet *internal.Tmeet) ([]string, error) {
	apiCmd := cmdutil.GetApiCmdAnnotation(cmd)
	if apiCmd == "" {
		log.Warnf(cmd.Context(), "no api cmd annotation found, compact skipped")
		return nil, nil
	}
	apiSchema, err := cmdutil.GetAPISchema(cmd.Context(), apiCmd, tmeet)
	if err != nil {
		return nil, err
	}
	return apiSchema.CompactFields, nil
}

// GetCompactFields returns the compact field list stored in ctx.
func GetCompactFields(ctx context.Context) []string {
	if fields, ok := ctx.Value(CompactFieldsKey).([]string); ok {
		return fields
	}
	return nil
}
