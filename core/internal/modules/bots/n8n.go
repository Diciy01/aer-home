package bots

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"slices"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/modules/monitoring"
)

// n8nAdapter reads n8n through its public REST API (X-N8N-API-KEY from a
// file): service health, workflows, executions. It never edits, activates
// or deactivates workflows; the only write is retrying a failed execution,
// when the instance allows it and the owner confirmed (ADR-012).
type n8nAdapter struct {
	s      *Service
	client *http.Client

	mu    sync.Mutex
	state map[string]*n8nState // by instance ID
}

type n8nState struct {
	status    string // ok | unavailable | unknown
	reason    string
	checkedAt *time.Time
	workflows []N8NWorkflow
}

func newN8NAdapter(s *Service) *n8nAdapter {
	return &n8nAdapter{s: s, client: &http.Client{Timeout: 15 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse // never follow a redirect with the API key
	}}, state: map[string]*n8nState{}}
}

func (a *n8nAdapter) Info(cfg config.Bots) AdapterInfo {
	inst := []AdapterInstance{}
	for _, n := range cfg.N8N {
		label := n.Label
		if label == "" {
			label = n.ID
		}
		allow := []string{}
		if n.AllowRetry {
			allow = append(allow, "job.retry")
		}
		u, _ := url.Parse(n.BaseURL)
		inst = append(inst, AdapterInstance{ID: n.ID, Label: label, Target: u.Host, Allow: allow})
	}
	st, reason := instancesStatus(len(inst), "экземпляра n8n")
	if st == "ok" {
		a.mu.Lock()
		bad := []string{}
		for _, n := range cfg.N8N {
			if s := a.state[n.ID]; s != nil && s.status != "ok" {
				bad = append(bad, n.ID+": "+s.reason)
			}
		}
		a.mu.Unlock()
		if len(bad) > 0 {
			st, reason = "unavailable", strings.Join(bad, "; ")
		}
	}
	return AdapterInfo{ID: "n8n", Label: "n8n", Status: st, Reason: reason,
		Description:  "Состояние сервиса, список workflows, последние выполнения и их ошибки; workflows не изменяются",
		Capabilities: []string{"monitor", "jobs", "retry", "check"}, Instances: inst}
}

type n8nError struct {
	status int
	msg    string
}

func (e *n8nError) Error() string { return e.msg }

func (a *n8nAdapter) request(ctx context.Context, inst config.N8NInstance, method, path string, body any, idem string, out any) error {
	key, err := os.ReadFile(inst.APIKeyFile)
	if err != nil {
		return &n8nError{msg: "Файл ключа API n8n недоступен (проверьте bots.n8n.apiKeyFile и права)"}
	}
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(inst.BaseURL, "/")+path, rd)
	if err != nil {
		return err
	}
	req.Header.Set("X-N8N-API-KEY", strings.TrimSpace(string(key)))
	req.Header.Set("Accept", "application/json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	if idem != "" {
		req.Header.Set("Idempotency-Key", idem)
	}
	resp, err := a.client.Do(req)
	if err != nil {
		return &n8nError{msg: "n8n не отвечает: " + netText(err)}
	}
	defer resp.Body.Close()
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return &n8nError{status: resp.StatusCode, msg: fmt.Sprintf("n8n отклонил ключ API (HTTP %d)", resp.StatusCode)}
	case resp.StatusCode == http.StatusNotFound:
		return &n8nError{status: 404, msg: "n8n: не найдено (HTTP 404; публичный API выключен или объект удалён)"}
	case resp.StatusCode >= 300:
		return &n8nError{status: resp.StatusCode, msg: fmt.Sprintf("n8n ответил HTTP %d", resp.StatusCode)}
	}
	if out == nil {
		return nil
	}
	return json.NewDecoder(io.LimitReader(resp.Body, 4<<20)).Decode(out)
}

func netText(err error) string {
	var ue *url.Error
	if errors.As(err, &ue) {
		err = ue.Err // the URL itself is not repeated in messages
	}
	if errors.Is(err, context.DeadlineExceeded) || strings.Contains(err.Error(), "timeout") {
		return "тайм-аут"
	}
	return monitoring.Redact(err.Error())
}

// flexID accepts n8n IDs encoded as strings or numbers.
type flexID string

func (f *flexID) UnmarshalJSON(b []byte) error {
	var s string
	if json.Unmarshal(b, &s) == nil {
		*f = flexID(s)
		return nil
	}
	var n json.Number
	if err := json.Unmarshal(b, &n); err != nil {
		return err
	}
	*f = flexID(n.String())
	return nil
}

type n8nExecution struct {
	ID         flexID     `json:"id"`
	Finished   bool       `json:"finished"`
	Mode       string     `json:"mode"`
	RetryOf    *flexID    `json:"retryOf"`
	StartedAt  *time.Time `json:"startedAt"`
	StoppedAt  *time.Time `json:"stoppedAt"`
	WorkflowID flexID     `json:"workflowId"`
	Status     string     `json:"status"`
}

func mapN8NStatus(e n8nExecution) JobStatus {
	switch e.Status {
	case "success":
		return JobSuccess
	case "error", "crashed":
		return JobFailed
	case "canceled":
		return JobCancelled
	case "running":
		return JobRunning
	case "new", "waiting":
		return JobPending
	}
	// Older n8n versions report only "finished".
	if e.Finished {
		return JobSuccess
	}
	if e.StoppedAt != nil {
		return JobFailed
	}
	return JobPending
}

// Sync refreshes every declared instance and the jobs of bots bound to it.
func (a *n8nAdapter) Sync(ctx context.Context) {
	if len(a.s.cfg.N8N) == 0 {
		return
	}
	bots, err := a.s.configs(ctx, "n8n_instance_id != ''")
	if err != nil {
		return
	}
	okCount := 0
	var reasons []string
	for _, inst := range a.s.cfg.N8N {
		st := a.refresh(ctx, inst)
		if st.status == "ok" {
			okCount++
		} else {
			reasons = append(reasons, inst.ID+": "+st.reason)
		}
		if st.status != "ok" {
			continue
		}
		for _, c := range bots {
			if c.N8NInstanceID == inst.ID {
				a.syncBot(ctx, inst, c, st)
			}
		}
	}
	if len(reasons) == 0 {
		a.s.mon.SetIntegrationStatus("n8n", "n8n", "ok", fmt.Sprintf("%d экземпляров отвечают", okCount))
	} else {
		a.s.mon.SetIntegrationStatus("n8n", "n8n", "unavailable", strings.Join(reasons, "; "))
	}
}

func (a *n8nAdapter) refresh(ctx context.Context, inst config.N8NInstance) n8nState {
	ctx, cancel := context.WithTimeout(ctx, time.Duration(a.s.cfg.OpTimeoutSec)*time.Second)
	defer cancel()
	now := a.s.now().UTC()
	st := n8nState{status: "ok", checkedAt: &now}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, strings.TrimRight(inst.BaseURL, "/")+"/healthz", nil)
	resp, err := a.client.Do(req)
	if err != nil {
		st.status, st.reason = "unavailable", "Сервис n8n не отвечает: "+netText(err)
	} else {
		resp.Body.Close()
		if resp.StatusCode != http.StatusOK {
			st.status, st.reason = "unavailable", fmt.Sprintf("/healthz ответил HTTP %d", resp.StatusCode)
		}
	}
	if st.status == "ok" {
		var wf struct {
			Data []struct {
				ID     flexID `json:"id"`
				Name   string `json:"name"`
				Active bool   `json:"active"`
			} `json:"data"`
		}
		if err := a.request(ctx, inst, http.MethodGet, "/api/v1/workflows?limit=250", nil, "", &wf); err != nil {
			st.status, st.reason = "unavailable", "Сервис работает, но API недоступен: "+err.Error()
		} else {
			for _, w := range wf.Data {
				st.workflows = append(st.workflows, N8NWorkflow{ID: string(w.ID), Name: w.Name, Active: w.Active})
			}
			st.reason = fmt.Sprintf("Сервис работает, workflows: %d", len(st.workflows))
		}
	}
	a.mu.Lock()
	a.state[inst.ID] = &st
	a.mu.Unlock()
	return st
}

func (a *n8nAdapter) syncBot(ctx context.Context, inst config.N8NInstance, c Config, st n8nState) {
	names := map[string]string{}
	for _, w := range st.workflows {
		names[w.ID] = w.Name
	}
	paths := []string{"/api/v1/executions?limit=50"}
	if len(c.N8NWorkflowIDs) > 0 {
		paths = paths[:0]
		for _, w := range c.N8NWorkflowIDs {
			paths = append(paths, "/api/v1/executions?limit=50&workflowId="+url.QueryEscape(w))
		}
	}
	newFailure, latest := false, (*Job)(nil)
	for _, p := range paths {
		var page struct {
			Data []n8nExecution `json:"data"`
		}
		if err := a.request(ctx, inst, http.MethodGet, p, nil, "", &page); err != nil {
			a.s.log.Warn("n8n executions", "instance", inst.ID, "err", err)
			return
		}
		for _, e := range page.Data {
			j := Job{EntityID: c.EntityID, ExternalID: "n8n:" + string(e.ID), Source: "n8n", Status: mapN8NStatus(e),
				StartedAt: e.StartedAt, FinishedAt: e.StoppedAt}
			j.Name = names[string(e.WorkflowID)]
			if j.Name == "" {
				j.Name = "workflow " + string(e.WorkflowID)
			}
			if e.Mode != "" {
				j.Result = "режим: " + e.Mode
			}
			if e.RetryOf != nil {
				j.RetryOf = "n8n:" + string(*e.RetryOf)
			}
			if j.Status == JobFailed {
				j.Error = "Выполнение завершилось со статусом " + e.Status
				j.Retryable = inst.AllowRetry
			}
			changed, err := a.s.upsertJob(ctx, j)
			if err != nil {
				return
			}
			if changed && j.Status == JobFailed {
				newFailure = true
				_ = a.s.mon.AppendLog(ctx, c.EntityID, "n8n:"+inst.ID, monitoring.LevelError,
					fmt.Sprintf("n8n: «%s» (выполнение %s) завершилось ошибкой", j.Name, e.ID))
			}
			if j.FinishedAt != nil && (latest == nil || j.FinishedAt.After(*latest.FinishedAt)) {
				jj := j
				latest = &jj
			}
		}
	}
	key := "n8n_failed:" + c.EntityID
	switch {
	case latest != nil && latest.Status == JobFailed && newFailure:
		a.s.mon.RaiseIncident(ctx, key, "Сценарий n8n завершился ошибкой", "bots/n8n", c.EntityID, monitoring.SeverityWarning,
			"n8n: статус error у «"+latest.Name+"»", "Последнее выполнение «"+latest.Name+"» завершилось ошибкой")
	case latest != nil && latest.Status == JobSuccess:
		a.s.mon.ResolveIncident(ctx, key, "Последнее выполнение «"+latest.Name+"» успешно")
	}
}

// Check verifies service health and API access of the bot's instance.
func (a *n8nAdapter) Check(ctx context.Context, b *Bot) (CheckResult, bool) {
	inst, ok := a.s.cfg.N8NByID(b.N8NInstanceID)
	if !ok {
		return CheckResult{}, false
	}
	st := a.refresh(ctx, inst)
	if st.status == "ok" {
		a.syncBot(ctx, inst, b.Config, st)
	}
	return CheckResult{OK: st.status == "ok", Message: "n8n: " + st.reason}, true
}

func (a *n8nAdapter) integration(c Config) *IntegrationInfo {
	inst, ok := a.s.cfg.N8NByID(c.N8NInstanceID)
	if !ok {
		return &IntegrationInfo{Kind: "n8n", Label: "n8n", Status: "disabled", Reason: "Экземпляр «" + c.N8NInstanceID + "» не объявлен в конфигурации Core"}
	}
	label := inst.Label
	if label == "" {
		label = inst.ID
	}
	info := &IntegrationInfo{Kind: "n8n", Label: label, Status: "unknown", Reason: "Ещё не проверялся", Workflows: []N8NWorkflow{}}
	a.mu.Lock()
	defer a.mu.Unlock()
	if st := a.state[inst.ID]; st != nil {
		info.Status, info.Reason, info.CheckedAt = st.status, st.reason, st.checkedAt
		for _, w := range st.workflows {
			if len(c.N8NWorkflowIDs) == 0 || slices.Contains(c.N8NWorkflowIDs, w.ID) {
				info.Workflows = append(info.Workflows, w)
			}
		}
	}
	return info
}

func (a *n8nAdapter) CanRetry(b *Bot, j Job) (bool, string) {
	if j.Source != "n8n" {
		return false, "Источник задания не поддерживает повтор"
	}
	inst, ok := a.s.cfg.N8NByID(b.N8NInstanceID)
	switch {
	case !ok:
		return false, "Экземпляр n8n не объявлен в конфигурации"
	case !inst.AllowRetry:
		return false, "Повтор выключен для этого экземпляра (bots.n8n.allowRetry)"
	case j.Status != JobFailed:
		return false, "Повторять можно только неудачное выполнение"
	}
	return true, ""
}

func (a *n8nAdapter) Retry(ctx context.Context, b *Bot, j Job, idem string) (string, error) {
	inst, _ := a.s.cfg.N8NByID(b.N8NInstanceID)
	id := strings.TrimPrefix(j.ExternalID, "n8n:")
	var out struct {
		ID flexID `json:"id"`
	}
	if err := a.request(ctx, inst, http.MethodPost, "/api/v1/executions/"+url.PathEscape(id)+"/retry",
		map[string]any{"loadWorkflow": false}, idem, &out); err != nil {
		return "", err
	}
	now := a.s.now().UTC()
	if out.ID != "" {
		_, _ = a.s.upsertJob(ctx, Job{EntityID: b.EntityID, ExternalID: "n8n:" + string(out.ID), Name: j.Name, Status: JobPending,
			Source: "n8n", StartedAt: &now, RetryOf: j.ExternalID})
	}
	return "n8n запустил повтор: выполнение " + string(out.ID), nil
}
