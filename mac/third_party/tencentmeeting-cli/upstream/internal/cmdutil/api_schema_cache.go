package cmdutil

import (
	"context"
	"encoding/json"
	"path/filepath"
	"sync"
	"time"

	"tmeet/internal"
	"tmeet/internal/config"
	"tmeet/internal/core/filecache"
	"tmeet/internal/log"
)

// schemaCacheSubDir is the sub-directory (relative to GetConfigDir) where
// compact-schema responses are persisted. Kept package-private so the
// on-disk layout can evolve without breaking external consumers.
const schemaCacheSubDir = "cache/schema"

// schemaCacheKeyExt is the file-name suffix appended to an apiCmd to form
// the filecache key; filecache itself is extension-agnostic, so callers
// own the naming convention.
const schemaCacheKeyExt = ".json"

// schemaCache is the process-wide filecache.Cache instance that stores
// APISchema payloads.
//
// A lazy sync.Once guard is used (rather than a plain package-level var =
// filecache.New(...) initializer) so that the TMEET_CLI_CONFIG_DIR env
// variable inspected by config.GetConfigDir() is honored even when tests
// mutate it after package initialization.
var (
	schemaCacheOnce sync.Once
	schemaCacheImpl *filecache.Cache

	// schemaFetchLocks serializes concurrent in-process fetches of the
	// same apiCmd. It is a zero-dependency substitute for singleflight:
	// in a CLI process concurrent fetches of the same apiCmd are
	// extremely rare, and the only correctness requirement is "don't
	// stampede the remote". A per-key mutex achieves that with no extra
	// modules. Keys are apiCmd strings, values are *sync.Mutex.
	schemaFetchLocks sync.Map
)

// getSchemaCache lazily builds the filecache.Cache singleton.
func getSchemaCache() *filecache.Cache {
	schemaCacheOnce.Do(func() {
		dir := filepath.Join(config.GetConfigDir(), schemaCacheSubDir)
		schemaCacheImpl = filecache.New(dir)
	})
	return schemaCacheImpl
}

// schemaCacheKey derives the filecache key for an apiCmd.
//
// filecache only accepts keys matching [A-Za-z0-9_.-] and rejects keys
// starting with '.', so any apiCmd string is safe because the existing
// ApiCmd* constants are all lowercase snake_case identifiers.
func schemaCacheKey(apiCmd string) string {
	return apiCmd + schemaCacheKeyExt
}

// loadSchemaCache tries to serve apiCmd from the on-disk cache.
//
// Return semantics:
//   - (schema, true):  fresh hit, caller may return it as-is.
//   - (nil, false):    miss / expired / corrupted / cache subsystem
//     unavailable. Caller must fall back to the remote endpoint.
//
// Any I/O or unmarshal error is logged at debug level and degraded to a
// miss so that a broken cache file never blocks the main flow.
func loadSchemaCache(ctx context.Context, apiCmd string) (*APISchema, bool) {
	if apiCmd == "" {
		return nil, false
	}
	payload, fresh, err := getSchemaCache().Get(schemaCacheKey(apiCmd))
	if err != nil {
		log.Errorf(ctx, "load api schema cache failed, apiCmd=%s, err=%v", apiCmd, err)
		return nil, false
	}
	if !fresh {
		return nil, false
	}
	schema := &APISchema{}
	if err := json.Unmarshal(payload, schema); err != nil {
		log.Errorf(ctx, "unmarshal api schema cache failed, apiCmd=%s, err=%v", apiCmd, err)
		return nil, false
	}
	return schema, true
}

// saveSchemaCache persists schema for apiCmd when (and only when) the
// server-side CacheConfig explicitly enables caching.
//
// This function never returns an error: callers treat caching as a
// best-effort optimisation, and any marshal / I/O failure is logged at
// warn level instead of propagated.
func saveSchemaCache(ctx context.Context, apiCmd string, schema *APISchema) {
	if apiCmd == "" || schema == nil {
		return
	}
	ttl := cacheTTL(schema.CacheConfig)
	if ttl <= 0 {
		// Server opted out (CacheConfig nil / Switch off / TTL<=0).
		// filecache.Set would also no-op on ttl<=0, but short-circuiting
		// here avoids the unnecessary JSON marshal cost.
		return
	}
	payload, err := json.Marshal(schema)
	if err != nil {
		log.Warnf(ctx, "marshal api schema for cache failed, apiCmd=%s, err=%v", apiCmd, err)
		return
	}
	if err := getSchemaCache().Set(schemaCacheKey(apiCmd), payload, ttl); err != nil {
		log.Warnf(ctx, "save api schema cache failed, apiCmd=%s, err=%v", apiCmd, err)
	}
}

// cacheTTL converts the server-declared APISchemaCacheConfig into a
// time.Duration. A nil config, Switch==false or a non-positive TTL all
// map to "do not cache" (0).
func cacheTTL(cfg *APISchemaCacheConfig) time.Duration {
	if cfg == nil || !cfg.Switch || cfg.TTL <= 0 {
		return 0
	}
	return time.Duration(cfg.TTL) * time.Second
}

// fetchAndCacheSchema calls fetchSchemaFromRemote with per-apiCmd
// in-process serialization, then writes the result back to the cache.
//
// The per-key mutex ensures that when two goroutines in the same process
// need to refresh the same apiCmd concurrently, only one of them hits
// the network; the other re-reads the freshly written cache and returns
// immediately. This is a lightweight, zero-dependency stand-in for
// golang.org/x/sync/singleflight that is sufficient for CLI workloads.
func fetchAndCacheSchema(ctx context.Context, apiCmd string, tmeet *internal.Tmeet) (*APISchema, error) {
	mu := apiSchemaFetchMutex(apiCmd)
	mu.Lock()
	defer mu.Unlock()

	// Double-check: another goroutine may have just populated the cache
	// while we were waiting on the mutex.
	if schema, ok := loadSchemaCache(ctx, apiCmd); ok {
		return schema, nil
	}

	schema, err := fetchSchemaFromRemote(ctx, apiCmd, tmeet)
	if err != nil {
		return nil, err
	}
	saveSchemaCache(ctx, apiCmd, schema)
	return schema, nil
}

// apiSchemaFetchMutex returns the per-apiCmd in-process mutex, creating
// it on first use. Using sync.Map.LoadOrStore guarantees that even under
// concurrent access every apiCmd ends up with exactly one *sync.Mutex.
func apiSchemaFetchMutex(apiCmd string) *sync.Mutex {
	if v, ok := schemaFetchLocks.Load(apiCmd); ok {
		return v.(*sync.Mutex)
	}
	mu := &sync.Mutex{}
	actual, _ := schemaFetchLocks.LoadOrStore(apiCmd, mu)
	return actual.(*sync.Mutex)
}
