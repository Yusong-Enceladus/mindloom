package cmdutil

import "github.com/spf13/cobra"

const (
	// annotationApiCmd API command.
	// use for query api compact fields and schema.
	annotationApiCmd = "apiCmd"
	// annotationSkipPreCheck skip pre-check.
	// use for nonLogin command.
	annotationSkipPreCheck = "skipPreCheck"
	// annotationSkipPreCheckFlag skip pre-check flag.
	// use for nonLogin command, but need to check flag.
	annotationSkipPreCheckFlag = "skipPreCheckFlag"
)

// InjectApiCmdAnnotation injects API command annotations.
func InjectApiCmdAnnotation(cmd *cobra.Command, apiCmdName string) {
	if cmd.Annotations == nil {
		cmd.Annotations = map[string]string{}
	}
	cmd.Annotations[annotationApiCmd] = apiCmdName
}

// GetApiCmdAnnotation gets API command annotations.
func GetApiCmdAnnotation(cmd *cobra.Command) string {
	if cmd.Annotations == nil {
		return ""
	}
	return cmd.Annotations[annotationApiCmd]
}

// InjectSkipPreCheckAnnotation injects skip pre-check annotations.
func InjectSkipPreCheckAnnotation(cmd *cobra.Command) {
	if cmd.Annotations == nil {
		cmd.Annotations = map[string]string{}
	}
	cmd.Annotations[annotationSkipPreCheck] = "true"
}

// InjectSkipPreCheckFlagAnnotation injects skip pre-check flag annotations.
func InjectSkipPreCheckFlagAnnotation(cmd *cobra.Command, flagName string) {
	if cmd.Annotations == nil {
		cmd.Annotations = map[string]string{}
	}
	cmd.Annotations[annotationSkipPreCheckFlag] = flagName
}
