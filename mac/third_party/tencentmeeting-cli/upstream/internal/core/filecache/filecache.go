// Package filecache provides a TTL-based local file cache primitive with
// cross-process safety built on top of core/filelock.
//
// Each key maps to a single envelope file under the configured directory,
// with a sibling .lock file guarding concurrent writes across processes.
// The cache is content-agnostic: payloads are opaque byte slices, and callers
// are responsible for choosing both the serialization format and the file
// extension (if any) by encoding it into the key itself, e.g. "schema.json".
package filecache

import (
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"tmeet/internal/core/filelock"
)

// lockFileExt is the suffix appended to the data file path to form the
// cross-process lock file path. It is an implementation detail and is not
// exposed to callers.
const lockFileExt = ".lock"

// tmpFilePrefix is the prefix for temporary files created during atomic writes.
const tmpFilePrefix = ".filecache-tmp-"

// dirPerm is the permission bits for the cache directory (owner rwx only).
const dirPerm os.FileMode = 0o700

// filePerm is the permission bits for cache data files (owner rw only).
const filePerm os.FileMode = 0o600

// Cache is a TTL-based key-value cache primitive backed by the local
// filesystem.
//
// A Cache value is safe for concurrent use by multiple goroutines within
// the same process. Cross-process safety is guaranteed on the write path
// through filelock; in-process safety is guaranteed by a per-key mutex.
// The read path is lock-free and degrades a corrupted file to a cache miss
// so that readers are never blocked by a broken entry.
type Cache struct {
	dir   string
	clock func() time.Time

	// mu guards the keys map; individual keyMu entries guard per-key writes.
	mu   sync.Mutex
	keys map[string]*sync.Mutex
}

// New constructs a Cache rooted at dir.
//
// The directory is not created eagerly. It is created lazily with 0o700
// permissions on the first successful Set call, so that the read path
// performs no side effects for caches that have never been written to.
func New(dir string) *Cache {
	return &Cache{
		dir:   dir,
		clock: defaultClock,
		keys:  make(map[string]*sync.Mutex),
	}
}

// keyMu returns the per-key mutex, creating one if it does not exist.
func (c *Cache) keyMu(key string) *sync.Mutex {
	c.mu.Lock()
	defer c.mu.Unlock()
	m, ok := c.keys[key]
	if !ok {
		m = &sync.Mutex{}
		c.keys[key] = m
	}
	return m
}

// Get reads the cache entry associated with key.
//
// Return value semantics:
//   - (payload, true, nil):  fresh hit within TTL; callers may use it directly.
//   - (nil, false, nil):     miss (not found / expired / corrupted / invalid
//     key). Callers should fall back to the upstream data source.
//   - (nil, false, err):     returned only on unrecoverable I/O errors such as
//     a permission failure on an existing directory, so that callers can
//     surface the issue in observability pipelines.
//
// The read path does not acquire the file lock: the write path uses the
// temp-file + rename sequence to guarantee atomicity, so a reader always
// observes either the complete old version or the complete new version and
// never a half-written file.
func (c *Cache) Get(key string) (payload []byte, fresh bool, err error) {
	if err := validateKey(key); err != nil {
		return nil, false, nil
	}

	raw, err := os.ReadFile(c.dataPath(key))
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, false, nil
		}
		return nil, false, fmt.Errorf("filecache: read %s: %w", key, err)
	}

	var env envelope
	if err := json.Unmarshal(raw, &env); err != nil {
		// Treat a corrupted file as a miss so that callers are not blocked;
		// the next successful Set will overwrite the broken entry.
		return nil, false, nil
	}

	if !env.isFresh(c.clock()) {
		return nil, false, nil
	}

	return env.Payload, true, nil
}

// Set writes a cache entry.
//
// A non-positive ttl is interpreted as "caller does not want to cache this
// entry"; Set returns nil without performing any I/O. This lets callers
// delegate the "should I cache?" decision to Cache itself and keeps the
// call sites symmetric.
//
// The write sequence is: acquire the in-process per-key mutex, acquire the
// cross-process lock, create the cache directory lazily, write a temporary
// file with fsync, then atomically rename it over the target file.
func (c *Cache) Set(key string, payload []byte, ttl time.Duration) error {
	if ttl <= 0 {
		return nil
	}
	if err := validateKey(key); err != nil {
		return err
	}

	env := envelope{
		CachedAt:   c.clock().Unix(),
		TTLSeconds: int64(ttl / time.Second),
		Payload:    append([]byte(nil), payload...),
	}
	data, err := json.Marshal(&env)
	if err != nil {
		return fmt.Errorf("filecache: marshal envelope: %w", err)
	}

	km := c.keyMu(key)
	km.Lock()
	defer km.Unlock()

	// Ensure the cache directory exists before taking the cross-process
	// lock: filelock opens the .lock file for writing, which fails with
	// ENOENT if its parent directory does not yet exist. Creating the
	// directory here keeps New() side-effect free while guaranteeing that
	// the subsequent lock and atomic write always have a valid parent.
	if err := os.MkdirAll(c.dir, dirPerm); err != nil {
		return fmt.Errorf("filecache: mkdir %s: %w", c.dir, err)
	}

	return filelock.WithLock(c.lockPath(key), func() error {
		return c.atomicWrite(key, data)
	})
}

// Delete removes the cache entry associated with key.
//
// A missing target file is treated as success, and an invalid key is also
// treated as success so that a typo on the caller side does not surface as
// an error. Delete still takes the cross-process lock to serialize with
// concurrent Set calls. The associated .lock file is also cleaned up.
func (c *Cache) Delete(key string) error {
	if err := validateKey(key); err != nil {
		return nil
	}

	km := c.keyMu(key)
	km.Lock()
	defer km.Unlock()

	// If the cache directory itself does not exist, there is nothing to
	// delete. Short-circuiting here also avoids filelock.WithLock failing
	// with ENOENT when it tries to open the .lock file inside a missing
	// parent directory.
	if _, statErr := os.Stat(c.dir); errors.Is(statErr, os.ErrNotExist) {
		return nil
	}

	lockPath := c.lockPath(key)
	err := filelock.WithLock(lockPath, func() error {
		rmErr := os.Remove(c.dataPath(key))
		if rmErr == nil || errors.Is(rmErr, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("filecache: remove %s: %w", key, rmErr)
	})
	if err != nil {
		return err
	}

	// Best-effort cleanup of the .lock file after the lock is released.
	_ = os.Remove(lockPath)
	return nil
}

// Purge removes all cache data files, temporary files, and lock files from
// the cache directory. It is intended for maintenance or graceful shutdown
// scenarios. Errors on individual file removals are collected but do not
// stop the sweep.
func (c *Cache) Purge() error {
	entries, err := os.ReadDir(c.dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return fmt.Errorf("filecache: purge readdir %s: %w", c.dir, err)
	}

	var firstErr error
	for _, entry := range entries {
		if entry.IsDir() {
			continue
		}
		name := entry.Name()
		// Remove .lock files, .tmp temporary files, and regular data files.
		if strings.HasSuffix(name, lockFileExt) ||
			strings.HasPrefix(name, tmpFilePrefix) ||
			isDataFile(name) {
			if rmErr := os.Remove(filepath.Join(c.dir, name)); rmErr != nil && firstErr == nil {
				firstErr = rmErr
			}
		}
	}
	return firstErr
}

// isDataFile reports whether name looks like a valid cache data file
// (passes key validation).
func isDataFile(name string) bool {
	return validateKey(name) == nil
}

// atomicWrite atomically replaces the target data file using the
// temp-file + fsync + rename pattern. The caller must already hold both
// the in-process mutex and the cross-process file lock for key, and must
// have ensured that c.dir exists (Set does this before taking the lock).
func (c *Cache) atomicWrite(key string, data []byte) error {
	// Use os.CreateTemp to generate a unique temporary file, avoiding
	// in-process concurrency conflicts on the file name.
	tmpFile, err := os.CreateTemp(c.dir, tmpFilePrefix)
	if err != nil {
		return fmt.Errorf("filecache: create tmp: %w", err)
	}
	tmpPath := tmpFile.Name()

	// Ensure the temporary file is cleaned up on any error path.
	defer func() { _ = os.Remove(tmpPath) }()

	if _, err = tmpFile.Write(data); err != nil {
		_ = tmpFile.Close()
		return fmt.Errorf("filecache: write tmp %s: %w", tmpPath, err)
	}
	// fsync ensures data is flushed to disk, preventing an empty file
	// after a crash.
	if err = tmpFile.Sync(); err != nil {
		_ = tmpFile.Close()
		return fmt.Errorf("filecache: sync tmp %s: %w", tmpPath, err)
	}
	if err = tmpFile.Close(); err != nil {
		return fmt.Errorf("filecache: close tmp %s: %w", tmpPath, err)
	}

	// Set the correct file permissions before rename.
	if err = os.Chmod(tmpPath, filePerm); err != nil {
		return fmt.Errorf("filecache: chmod tmp %s: %w", tmpPath, err)
	}

	dataPath := c.dataPath(key)
	if err = os.Rename(tmpPath, dataPath); err != nil {
		return fmt.Errorf("filecache: rename %s -> %s: %w", tmpPath, dataPath, err)
	}
	return nil
}

// dataPath returns the absolute path of the data file for key. The key is
// used verbatim as the file name; any extension (if desired) must be
// encoded by the caller into the key itself.
func (c *Cache) dataPath(key string) string {
	return filepath.Join(c.dir, key)
}

// lockPath returns the absolute path of the cross-process lock file for
// key. The lock file is derived from the data file by appending the .lock
// suffix; this is an internal detail and does not constrain how callers
// name their keys.
func (c *Cache) lockPath(key string) string {
	return filepath.Join(c.dir, key+lockFileExt)
}
