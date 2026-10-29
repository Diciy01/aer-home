package remotehost

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"net/http/httptest"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"testing"
)

func TestFileChannelConcurrentUploadsNeverOverwrite(t *testing.T) {
	f := NewFileServer(t.TempDir(), 1024)
	f.token = "TEST-ONLY-session"
	var created atomic.Int32
	var wg sync.WaitGroup
	for i := range 16 {
		wg.Add(1)
		go func() {
			defer wg.Done()
			body := bytes.Repeat([]byte{byte(i + 1)}, 64)
			hash := sha256.Sum256(body)
			req := httptest.NewRequest("PUT", "/v1/files/one.bin", bytes.NewReader(body))
			req.Header.Set("Authorization", "Bearer TEST-ONLY-session")
			req.Header.Set("X-AER-SHA256", hex.EncodeToString(hash[:]))
			res := httptest.NewRecorder()
			f.ServeHTTP(res, req)
			if res.Code == 201 {
				created.Add(1)
			} else if res.Code != 409 {
				t.Errorf("upload status %d", res.Code)
			}
		}()
	}
	wg.Wait()
	if created.Load() != 1 {
		t.Fatalf("successful writes %d", created.Load())
	}
	b, err := os.ReadFile(filepath.Join(f.dir, "one.bin"))
	if err != nil || len(b) != 64 {
		t.Fatalf("published file %d bytes, %v", len(b), err)
	}
	if !bytes.Equal(b, bytes.Repeat(b[:1], len(b))) {
		t.Fatal("mixed concurrent upload contents")
	}
}
func TestFileChannelDownloadSizeLimit(t *testing.T) {
	f := NewFileServer(t.TempDir(), 3)
	f.token = "TEST-ONLY-session"
	if err := os.WriteFile(filepath.Join(f.dir, "large.bin"), []byte("four"), 0600); err != nil {
		t.Fatal(err)
	}
	req := httptest.NewRequest("GET", "/v1/files/large.bin", nil)
	req.Header.Set("Authorization", "Bearer TEST-ONLY-session")
	res := httptest.NewRecorder()
	f.ServeHTTP(res, req)
	if res.Code != 413 {
		t.Fatalf("download status %d", res.Code)
	}
}
