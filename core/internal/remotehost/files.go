package remotehost

import (
	"context"
	"crypto/sha256"
	"crypto/subtle"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

// FileServer is the session file channel: HTTPS on this host with the
// pinned RDP certificate, one bearer token per session, only the exchange
// folder, a size limit and SHA-256 integrity. It listens only while a
// session with files allowed is open.
type FileServer struct {
	dir      string
	maxBytes int64

	mu    sync.Mutex
	token string
	srv   *http.Server
}

// NewFileServer prepares (does not start) the server.
func NewFileServer(dir string, maxBytes int64) *FileServer {
	return &FileServer{dir: dir, maxBytes: maxBytes}
}

// Start listens on addr with the given certificate for one session token.
func (f *FileServer) Start(addr, certFile, keyFile, token string) error {
	if err := os.MkdirAll(f.dir, 0o700); err != nil {
		return err
	}
	cert, err := tls.LoadX509KeyPair(certFile, keyFile)
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		return err
	}
	f.mu.Lock()
	f.token = token
	f.srv = &http.Server{Handler: f, ReadHeaderTimeout: 10 * time.Second,
		TLSConfig: &tls.Config{Certificates: []tls.Certificate{cert}, MinVersion: tls.VersionTLS12}}
	srv := f.srv
	f.mu.Unlock()
	go srv.Serve(tls.NewListener(ln, srv.TLSConfig))
	return nil
}

// Stop closes the listener and forgets the token at once.
func (f *FileServer) Stop() {
	f.mu.Lock()
	srv := f.srv
	f.srv, f.token = nil, ""
	f.mu.Unlock()
	if srv != nil {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		_ = srv.Shutdown(ctx)
		cancel()
		_ = srv.Close()
	}
}

// FileInfo is one file of the exchange folder.
type FileInfo struct {
	Name     string    `json:"name"`
	Size     int64     `json:"size"`
	Modified time.Time `json:"modified"`
}

// validName allows plain file names only: no paths, no hidden files.
func validName(n string) bool {
	return n != "" && len(n) <= 200 && utf8.ValidString(n) && !strings.ContainsAny(n, "/\\\x00") &&
		!strings.HasPrefix(n, ".") && n == filepath.Base(n)
}

func (f *FileServer) authorized(r *http.Request) bool {
	f.mu.Lock()
	tok := f.token
	f.mu.Unlock()
	got, ok := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return ok && tok != "" && subtle.ConstantTimeCompare([]byte(got), []byte(tok)) == 1
}

func jsonErr(w http.ResponseWriter, code int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(code)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

func (f *FileServer) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	if !f.authorized(r) {
		jsonErr(w, http.StatusUnauthorized, "нужен токен сеанса")
		return
	}
	name, isFile := strings.CutPrefix(r.URL.Path, "/v1/files/")
	switch {
	case r.URL.Path == "/v1/files" && r.Method == http.MethodGet:
		f.list(w)
	case isFile && r.Method == http.MethodGet:
		f.download(w, r, name)
	case isFile && r.Method == http.MethodPut:
		f.upload(w, r, name)
	default:
		jsonErr(w, http.StatusNotFound, "нет такого действия")
	}
}

func (f *FileServer) list(w http.ResponseWriter) {
	ents, err := os.ReadDir(f.dir)
	if err != nil {
		jsonErr(w, http.StatusInternalServerError, "папка обмена недоступна")
		return
	}
	out := []FileInfo{}
	for _, e := range ents {
		if !e.Type().IsRegular() || !validName(e.Name()) {
			continue // no subfolders, links or hidden files
		}
		if fi, err := e.Info(); err == nil {
			out = append(out, FileInfo{Name: e.Name(), Size: fi.Size(), Modified: fi.ModTime().UTC()})
		}
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Modified.After(out[j].Modified) })
	w.Header().Set("Content-Type", "application/json")
	_ = json.NewEncoder(w).Encode(map[string]any{"files": out, "maxBytes": f.maxBytes})
}

func (f *FileServer) download(w http.ResponseWriter, r *http.Request, name string) {
	if !validName(name) {
		jsonErr(w, http.StatusBadRequest, "недопустимое имя файла")
		return
	}
	p := filepath.Join(f.dir, name)
	fi, err := os.Lstat(p)
	if err != nil || !fi.Mode().IsRegular() {
		jsonErr(w, http.StatusNotFound, "файл не найден")
		return
	}
	fh, err := os.Open(p)
	if err != nil {
		jsonErr(w, http.StatusInternalServerError, "не удалось открыть файл")
		return
	}
	defer fh.Close()
	h := sha256.New()
	if _, err := io.Copy(h, fh); err != nil {
		jsonErr(w, http.StatusInternalServerError, "ошибка чтения")
		return
	}
	_, _ = fh.Seek(0, io.SeekStart)
	w.Header().Set("Content-Type", "application/octet-stream")
	w.Header().Set("Content-Length", strconv.FormatInt(fi.Size(), 10))
	w.Header().Set("X-AER-SHA256", hex.EncodeToString(h.Sum(nil)))
	_, _ = io.Copy(w, fh)
}

func (f *FileServer) upload(w http.ResponseWriter, r *http.Request, name string) {
	if !validName(name) {
		jsonErr(w, http.StatusBadRequest, "недопустимое имя файла")
		return
	}
	want := strings.ToLower(r.Header.Get("X-AER-SHA256"))
	if len(want) != 64 {
		jsonErr(w, http.StatusBadRequest, "нужен заголовок X-AER-SHA256")
		return
	}
	if r.ContentLength > f.maxBytes {
		jsonErr(w, http.StatusRequestEntityTooLarge, fmt.Sprintf("файл больше лимита %d байт", f.maxBytes))
		return
	}
	final := filepath.Join(f.dir, name)
	if _, err := os.Lstat(final); err == nil {
		jsonErr(w, http.StatusConflict, "файл с таким именем уже есть — не перезаписываем")
		return
	}
	tmp, err := os.CreateTemp(f.dir, ".aer-upload-*")
	if err != nil {
		jsonErr(w, http.StatusInternalServerError, "не удалось создать файл")
		return
	}
	defer os.Remove(tmp.Name()) // no-op after a successful rename
	h := sha256.New()
	n, err := io.Copy(io.MultiWriter(tmp, h), http.MaxBytesReader(w, r.Body, f.maxBytes))
	tmp.Close()
	var tooBig *http.MaxBytesError
	switch {
	case errors.As(err, &tooBig):
		jsonErr(w, http.StatusRequestEntityTooLarge, "файл больше лимита")
		return
	case err != nil:
		jsonErr(w, http.StatusBadRequest, "передача прервана") // cancelled or network loss: partial file removed
		return
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != want {
		jsonErr(w, http.StatusUnprocessableEntity, "контрольная сумма не совпала — файл отброшен")
		return
	}
	if err := os.Rename(tmp.Name(), final); err != nil {
		jsonErr(w, http.StatusInternalServerError, "не удалось сохранить файл")
		return
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(http.StatusCreated)
	_ = json.NewEncoder(w).Encode(map[string]any{"name": name, "size": n, "sha256": want})
}
