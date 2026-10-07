package cmdutil

import (
	"strconv"
	"tmeet/internal/exception"
	"tmeet/internal/output"

	"github.com/spf13/cobra"
)

// Pagination query field names.
const (
	// PageSizeMaxMeetings page size max meetings
	PageSizeMaxMeetings = 30
	// PageSizeMaxRecords page size max records
	PageSizeMaxRecords = 30
	// PageSizeMaxReports page size max reports
	PageSizeMaxReports = 100

	// PageTypeOld page type old
	PageTypeOld = 0
	// PageTypeToken page type token
	PageTypeToken = 1
)

// ClampingPageSize clamping page size.
func ClampingPageSize(cmd *cobra.Command, pageSize, maxPageSize int) (int, error) {
	if pageSize < 1 {
		return 0, exception.InvalidArgsError.With(
			"illegal page size, must larger equal than 1 and less equal than %d", maxPageSize)
	}
	if pageSize > maxPageSize {
		output.PrintErrorf(cmd, "page-size clamped to %d (valid range: 1~%d)", maxPageSize, maxPageSize)
		return maxPageSize, nil
	}
	return pageSize, nil
}

// ChoosePageOrToken picks the proper pagination field and value.
// Since CLI v1.0.5 page_token is the unified pagination parameter; the legacy
// page parameter is deprecated but still supported with lower priority, and
// defaults to 0. It returns the field name and its string value.
func ChoosePageOrToken(page int, pageToken string) (string, int) {
	if pageToken != "" {
		return pageToken, PageTypeToken
	}
	if page > 0 {
		return strconv.Itoa(page), PageTypeOld
	}
	return "", PageTypeToken
}

// ChoosePosOrToken picks the proper pagination field and value.
// Since CLI v1.0.5 page_token is the unified pagination parameter; the legacy
// pos parameter is deprecated but still supported with lower priority, and
// defaults to -1. It returns the field name and its string value.
func ChoosePosOrToken(pos int, pageToken string) (string, int) {
	if pageToken != "" {
		return pageToken, PageTypeToken
	}
	if pos >= 0 {
		return strconv.Itoa(pos), PageTypeOld
	}
	return "", PageTypeToken
}
