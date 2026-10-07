package filecache

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"
)

func TestCache_MissOnEmptyDir(t *testing.T) {
	c := New(t.TempDir())
	payload, fresh, err := c.Get("any")
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if fresh || payload != nil {
		t.Fatalf("expected miss on empty dir, got fresh=%v payload=%q", fresh, payload)
	}
}

func TestCache_SetThenGetFresh(t *testing.T) {
	c := New(t.TempDir())
	want := []byte("hello-payload")
	if err := c.Set("api.meetings.create", want, time.Hour); err != nil {
		t.Fatalf("Set: %v", err)
	}

	got, fresh, err := c.Get("api.meetings.create")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !fresh {
		t.Fatal("expected fresh hit")
	}
	if !bytes.Equal(got, want) {
		t.Fatalf("payload mismatch: got=%q want=%q", got, want)
	}
}

func TestCache_ExpiredMiss(t *testing.T) {
	c := New(t.TempDir())

	// Freeze the write moment at t0.
	t0 := time.Unix(1_700_000_000, 0)
	c.clock = func() time.Time { return t0 }

	if err := c.Set("k", []byte("v"), 10*time.Second); err != nil {
		t.Fatalf("Set: %v", err)
	}

	// Advance the clock past the TTL.
	c.clock = func() time.Time { return t0.Add(11 * time.Second) }

	_, fresh, err := c.Get("k")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if fresh {
		t.Fatal("expected expired miss")
	}
}

func TestCache_Set_NonPositiveTTLNoop(t *testing.T) {
	dir := t.TempDir()
	c := New(dir)

	if err := c.Set("k", []byte("v"), 0); err != nil {
		t.Fatalf("Set ttl=0: %v", err)
	}
	if err := c.Set("k", []byte("v"), -time.Second); err != nil {
		t.Fatalf("Set ttl=-1s: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("expected empty dir, got %d entries", len(entries))
	}
}

func TestCache_CorruptedFileAsMiss(t *testing.T) {
	dir := t.TempDir()
	c := New(dir)

	if err := os.MkdirAll(dir, dirPerm); err != nil {
		t.Fatalf("MkdirAll: %v", err)
	}
	if err := os.WriteFile(filepath.Join(dir, "k"), []byte("{not json"), filePerm); err != nil {
		t.Fatalf("WriteFile: %v", err)
	}

	_, fresh, err := c.Get("k")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if fresh {
		t.Fatal("expected miss on corrupted file")
	}
}

func TestCache_Delete(t *testing.T) {
	c := New(t.TempDir())

	if err := c.Set("k", []byte("v"), time.Hour); err != nil {
		t.Fatalf("Set: %v", err)
	}
	if err := c.Delete("k"); err != nil {
		t.Fatalf("Delete: %v", err)
	}
	if _, fresh, _ := c.Get("k"); fresh {
		t.Fatal("expected miss after Delete")
	}

	// Idempotent: a second Delete must not surface an error.
	if err := c.Delete("k"); err != nil {
		t.Fatalf("Delete idempotent: %v", err)
	}

	// .lock file should also be cleaned up.
	lockPath := filepath.Join(c.dir, "k"+lockFileExt)
	if _, err := os.Stat(lockPath); !os.IsNotExist(err) {
		t.Fatalf("expected .lock file to be removed, got err=%v", err)
	}
}

func TestCache_InvalidKey(t *testing.T) {
	c := New(t.TempDir())

	badKeys := []string{"", "../escape", "a/b", ".hidden", "has space", "utf8-中文"}
	for _, k := range badKeys {
		if _, fresh, err := c.Get(k); err != nil || fresh {
			t.Errorf("Get(%q) should miss, got fresh=%v err=%v", k, fresh, err)
		}
		if err := c.Set(k, []byte("v"), time.Hour); err == nil {
			t.Errorf("Set(%q) should fail with invalid key", k)
		}
		if err := c.Delete(k); err != nil {
			t.Errorf("Delete(%q) should be noop, got err=%v", k, err)
		}
	}
}

func TestCache_KeyTooLong(t *testing.T) {
	c := New(t.TempDir())

	longKey := strings.Repeat("a", maxKeyLen+1)
	if err := c.Set(longKey, []byte("v"), time.Hour); err == nil {
		t.Fatal("Set with too-long key should fail")
	}

	// Exactly at the limit should succeed.
	okKey := strings.Repeat("b", maxKeyLen)
	if err := c.Set(okKey, []byte("v"), time.Hour); err != nil {
		t.Fatalf("Set with max-length key: %v", err)
	}
}

func TestCache_ConcurrentSetSameKey(t *testing.T) {
	c := New(t.TempDir())

	const n = 16
	var wg sync.WaitGroup
	var failed int32

	for i := 0; i < n; i++ {
		wg.Add(1)
		go func(idx int) {
			defer wg.Done()
			payload := []byte(fmt.Sprintf("v-%d", idx))
			if err := c.Set("shared", payload, time.Hour); err != nil {
				atomic.AddInt32(&failed, 1)
				t.Errorf("Set: %v", err)
			}
		}(i)
	}
	wg.Wait()

	if atomic.LoadInt32(&failed) > 0 {
		t.Fatalf("%d concurrent Set(s) failed", failed)
	}

	got, fresh, err := c.Get("shared")
	if err != nil {
		t.Fatalf("Get: %v", err)
	}
	if !fresh {
		t.Fatal("expected fresh hit after concurrent writes")
	}
	if len(got) == 0 {
		t.Fatal("expected non-empty payload from one of the concurrent writers")
	}
}

func TestCache_Purge(t *testing.T) {
	dir := t.TempDir()
	c := New(dir)

	// Write several cache entries.
	for _, k := range []string{"a", "b", "c"} {
		if err := c.Set(k, []byte("data-"+k), time.Hour); err != nil {
			t.Fatalf("Set(%s): %v", k, err)
		}
	}

	// Purge should remove all files.
	if err := c.Purge(); err != nil {
		t.Fatalf("Purge: %v", err)
	}

	entries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("ReadDir: %v", err)
	}
	if len(entries) != 0 {
		names := make([]string, 0, len(entries))
		for _, e := range entries {
			names = append(names, e.Name())
		}
		t.Fatalf("expected empty dir after Purge, got: %v", names)
	}
}

func TestCache_PurgeEmptyDir(t *testing.T) {
	c := New(filepath.Join(t.TempDir(), "nonexistent"))
	// Purge on non-existent dir should not error.
	if err := c.Purge(); err != nil {
		t.Fatalf("Purge on non-existent dir: %v", err)
	}
}
