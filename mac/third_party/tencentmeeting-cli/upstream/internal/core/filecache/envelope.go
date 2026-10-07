package filecache

import (
	"errors"
	"time"
)

// maxKeyLen is the maximum allowed key length. File systems typically
// limit file names to 255 bytes; we reserve space for the ".lock" suffix
// and the ".tmp.XXXXXXXXXX" pattern used during atomic writes.
const maxKeyLen = 200

// errInvalidKey is returned when a key contains illegal characters or
// attempts path traversal. It is only surfaced on the Set path; Get and
// Delete degrade it into a miss / no-op respectively.
var errInvalidKey = errors.New("filecache: invalid key")

// envelope is the JSON envelope persisted to disk.
//
// Using an envelope instead of storing the raw payload directly decouples
// the business data from cache metadata: the payload format can evolve
// freely without forcing a schema change on the envelope itself.
type envelope struct {
	// CachedAt is the UNIX timestamp (in seconds) when the entry was written.
	CachedAt int64 `json:"cached_at"`
	// TTLSeconds is the lifetime of the entry in seconds; a non-positive
	// value is treated as "already expired".
	TTLSeconds int64 `json:"ttl_seconds"`
	// Payload is the opaque business data; it is base64-encoded by the JSON
	// codec because []byte is its wire representation.
	Payload []byte `json:"payload"`
}

// isFresh reports whether the entry is still within its TTL.
func (e envelope) isFresh(now time.Time) bool {
	if e.TTLSeconds <= 0 {
		return false
	}
	expireAt := e.CachedAt + e.TTLSeconds
	return now.Unix() < expireAt
}

// validateKey reports whether key is legal for use as a cache filename.
//
// Only letters, digits, '_', '-' and '.' are allowed; this avoids path
// traversal and sidesteps cross-filesystem compatibility issues. Keys
// starting with '.' are rejected to prevent the creation of hidden files.
// Keys exceeding maxKeyLen bytes are rejected to avoid ENAMETOOLONG.
func validateKey(key string) error {
	if key == "" || len(key) > maxKeyLen {
		return errInvalidKey
	}
	if key[0] == '.' {
		return errInvalidKey
	}
	for i := 0; i < len(key); i++ {
		c := key[i]
		switch {
		case c >= 'a' && c <= 'z':
		case c >= 'A' && c <= 'Z':
		case c >= '0' && c <= '9':
		case c == '_' || c == '-' || c == '.':
		default:
			return errInvalidKey
		}
	}
	return nil
}

// defaultClock is the default time source used by Cache instances.
func defaultClock() time.Time { return time.Now() }
