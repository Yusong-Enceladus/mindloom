package utils

import (
	"testing"
	"tmeet/internal/exception"
)

// TestCharacterLimit tests CharacterLimit with various scenarios.
func TestCharacterLimit(t *testing.T) {
	tests := []struct {
		name    string
		str     string
		limit   int
		wantErr bool
	}{
		{
			name:    "empty string within limit",
			str:     "",
			limit:   10,
			wantErr: false,
		},
		{
			name:    "empty string with zero limit",
			str:     "",
			limit:   0,
			wantErr: false,
		},
		{
			name:    "ascii string under limit",
			str:     "hello",
			limit:   10,
			wantErr: false,
		},
		{
			name:    "ascii string exactly at limit",
			str:     "hello",
			limit:   5,
			wantErr: false,
		},
		{
			name:    "ascii string exceeds limit",
			str:     "hello world",
			limit:   5,
			wantErr: true,
		},
		{
			name:    "chinese string under limit",
			str:     "腾讯会议",
			limit:   10,
			wantErr: false,
		},
		{
			name:    "chinese string exactly at limit",
			str:     "腾讯会议",
			limit:   4,
			wantErr: false,
		},
		{
			name:    "chinese string exceeds limit",
			str:     "腾讯会议命令行工具",
			limit:   4,
			wantErr: true,
		},
		{
			name:    "mixed chars under limit",
			str:     "tmeet腾讯会议",
			limit:   20,
			wantErr: false,
		},
		{
			name:    "emoji string by rune count",
			str:     "😀😁😂",
			limit:   3,
			wantErr: false,
		},
		{
			name:    "emoji string exceeds limit",
			str:     "😀😁😂😃",
			limit:   3,
			wantErr: true,
		},
		{
			name:    "non-empty string with zero limit",
			str:     "a",
			limit:   1,
			wantErr: false,
		},
		{
			name:    "non-empty string with zero limit exceeds",
			str:     "a",
			limit:   0,
			wantErr: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			err := CharacterLimit("test", tt.str, tt.limit)
			if tt.wantErr {
				if err == nil {
					t.Errorf("expected error, but got nil")
					return
				}
				// 验证错误类型为 InvalidArgsError
				if !exception.Is(err, exception.InvalidArgsError) {
					t.Errorf("expected InvalidArgsError, but got: %v", err)
				}
			} else if err != nil {
				t.Errorf("unexpected error: %v", err)
			}
		})
	}
}
