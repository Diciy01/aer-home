package bots

import (
	"context"
	"database/sql"
	"errors"
	"fmt"
	"strings"
	"time"

	"aerhome/core/internal/foundation/ids"
	"aerhome/core/internal/modules/monitoring"
)

const maxJobsPerReport = 200

// JobIn is one job reported by a bot through its heartbeat credential.
type JobIn struct {
	ID         string     `json:"id"`
	Name       string     `json:"name"`
	Status     JobStatus  `json:"status"`
	StartedAt  *time.Time `json:"startedAt"`
	FinishedAt *time.Time `json:"finishedAt"`
	Result     string     `json:"result"`
	Error      string     `json:"error"`
}

// JobReport is the body of POST /bots/agent/jobs.
type JobReport struct {
	Jobs []JobIn `json:"jobs"`
}

// IngestJobs stores jobs a bot reports about itself. Heartbeat jobs are
// never retryable from AER: there is no channel to ask the bot to re-run.
func (s *Service) IngestJobs(ctx context.Context, entityID string, r JobReport) (int, error) {
	if _, err := s.config(ctx, entityID); err != nil {
		return 0, ErrNotABot
	}
	v := &ValidationError{}
	if len(r.Jobs) > maxJobsPerReport {
		v.add("jobs", fmt.Sprintf("Не больше %d заданий в отчёте", maxJobsPerReport))
	}
	now := s.now().UTC()
	for i, j := range r.Jobs {
		p := fmt.Sprintf("jobs[%d]", i)
		if j.ID == "" || len(j.ID) > 80 {
			v.add(p+".id", "Идентификатор задания: 1–80 символов")
		}
		if strings.TrimSpace(j.Name) == "" || len([]rune(j.Name)) > 120 {
			v.add(p+".name", "Название: 1–120 символов")
		}
		if !jobStatuses[j.Status] {
			v.add(p+".status", "pending, running, success, failed или cancelled")
		}
		for _, t := range []*time.Time{j.StartedAt, j.FinishedAt} {
			if t != nil && (t.Before(now.Add(-30*24*time.Hour)) || t.After(now.Add(5*time.Minute))) {
				v.add(p, "Время вне окна −30 дней…+5 минут (проверьте часы)")
			}
		}
		if j.StartedAt != nil && j.FinishedAt != nil && j.FinishedAt.Before(*j.StartedAt) {
			v.add(p+".finishedAt", "Завершение раньше запуска")
		}
	}
	if err := v.orNil(); err != nil {
		return 0, err
	}
	n := 0
	for _, in := range r.Jobs {
		j := Job{EntityID: entityID, ExternalID: "hb:" + in.ID, Name: in.Name, Status: in.Status, Source: "heartbeat",
			StartedAt: in.StartedAt, FinishedAt: in.FinishedAt, Result: in.Result, Error: in.Error}
		changed, err := s.upsertJob(ctx, j)
		if err != nil {
			return n, err
		}
		n++
		if changed && j.Status == JobFailed {
			_ = s.mon.AppendLog(ctx, entityID, "bot.jobs", monitoring.LevelError, "Задание «"+j.Name+"» завершилось ошибкой: "+j.Error)
		}
	}
	return n, nil
}

// upsertJob inserts or updates a job by (entity, external id). changed is
// true when the job is new or its status changed.
func (s *Service) upsertJob(ctx context.Context, j Job) (bool, error) {
	j.Name = truncate(j.Name, 120)
	j.Result = truncate(monitoring.Redact(j.Result), 2000)
	j.Error = truncate(monitoring.Redact(j.Error), 2000)
	var dur any
	if j.StartedAt != nil && j.FinishedAt != nil {
		dur = j.FinishedAt.Sub(*j.StartedAt).Milliseconds()
	}
	var prev string
	err := s.db.QueryRowContext(ctx, `SELECT status FROM bot_jobs WHERE entity_id = ? AND external_id = ?`, j.EntityID, j.ExternalID).Scan(&prev)
	if err != nil && !errors.Is(err, sql.ErrNoRows) {
		return false, err
	}
	if _, err := s.db.ExecContext(ctx, `INSERT INTO bot_jobs (id, entity_id, external_id, name, status, source, started_at, finished_at,
		duration_ms, result, error, retryable, retry_of, updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)
		ON CONFLICT (entity_id, external_id) DO UPDATE SET name = excluded.name, status = excluded.status,
		started_at = COALESCE(excluded.started_at, bot_jobs.started_at), finished_at = excluded.finished_at,
		duration_ms = excluded.duration_ms, result = excluded.result, error = excluded.error,
		retryable = excluded.retryable, retry_of = CASE WHEN excluded.retry_of != '' THEN excluded.retry_of ELSE bot_jobs.retry_of END,
		updated_at = excluded.updated_at
		WHERE bot_jobs.status != excluded.status OR bot_jobs.finished_at IS NOT excluded.finished_at OR bot_jobs.name != excluded.name`,
		ids.New(), j.EntityID, j.ExternalID, j.Name, string(j.Status), j.Source, nullTime(j.StartedAt), nullTime(j.FinishedAt),
		dur, j.Result, j.Error, boolInt(j.Retryable), j.RetryOf, ms(s.now())); err != nil {
		return false, err
	}
	return prev != string(j.Status), nil
}

func nullTime(t *time.Time) any {
	if t == nil {
		return nil
	}
	return ms(*t)
}

func boolInt(b bool) int {
	if b {
		return 1
	}
	return 0
}

const jobCols = `id, entity_id, external_id, name, status, source, started_at, finished_at, duration_ms, result, error, retryable, retry_of`

func scanJob(row interface{ Scan(...any) error }) (Job, error) {
	var j Job
	var st string
	var started, finished, dur sql.NullInt64
	var retry int
	if err := row.Scan(&j.ID, &j.EntityID, &j.ExternalID, &j.Name, &st, &j.Source, &started, &finished, &dur,
		&j.Result, &j.Error, &retry, &j.RetryOf); err != nil {
		return j, err
	}
	j.Status, j.Retryable = JobStatus(st), retry == 1
	j.StartedAt, j.FinishedAt = fromNullMS(started), fromNullMS(finished)
	if dur.Valid {
		d := dur.Int64
		j.DurationMs = &d
	}
	return j, nil
}

// JobPage is a page of jobs, newest first (cursor: the last job's id).
type JobPage struct {
	Items      []Job   `json:"items"`
	NextBefore *string `json:"nextBefore"`
	Total      int     `json:"total"`
}

// Jobs lists the bot's jobs; before is NextBefore of the previous page.
func (s *Service) Jobs(ctx context.Context, entityID, status, before string, limit int) (JobPage, error) {
	if _, err := s.config(ctx, entityID); err != nil {
		return JobPage{}, err
	}
	if limit <= 0 || limit > 200 {
		limit = 50
	}
	where := "entity_id = ?"
	args := []any{entityID}
	if status != "" {
		if !jobStatuses[JobStatus(status)] {
			return JobPage{}, &ValidationError{Fields: map[string]string{"status": "pending, running, success, failed или cancelled"}}
		}
		where += " AND status = ?"
		args = append(args, status)
	}
	page := JobPage{Items: []Job{}}
	if err := s.db.QueryRowContext(ctx, `SELECT COUNT(*) FROM bot_jobs WHERE `+where, args...).Scan(&page.Total); err != nil {
		return page, err
	}
	if before != "" {
		where += " AND (updated_at, id) < (SELECT updated_at, id FROM bot_jobs WHERE id = ?)"
		args = append(args, before)
	}
	rows, err := s.db.QueryContext(ctx, `SELECT `+jobCols+` FROM bot_jobs WHERE `+where+
		` ORDER BY updated_at DESC, id DESC LIMIT ?`, append(args, limit+1)...)
	if err != nil {
		return page, err
	}
	defer rows.Close()
	for rows.Next() {
		j, err := scanJob(rows)
		if err != nil {
			return page, err
		}
		page.Items = append(page.Items, j)
	}
	if len(page.Items) > limit {
		page.Items = page.Items[:limit]
		next := page.Items[limit-1].ID
		page.NextBefore = &next
	}
	return page, rows.Err()
}

func (s *Service) job(ctx context.Context, entityID, id string) (Job, error) {
	j, err := scanJob(s.db.QueryRowContext(ctx, `SELECT `+jobCols+` FROM bot_jobs WHERE entity_id = ? AND id = ?`, entityID, id))
	if errors.Is(err, sql.ErrNoRows) {
		return j, ErrNotFound
	}
	return j, err
}

// jobSummary fills the last successful/failed job and 24-hour counts.
func (s *Service) jobSummary(ctx context.Context, b *Bot) error {
	last := func(status JobStatus) (*Job, error) {
		j, err := scanJob(s.db.QueryRowContext(ctx, `SELECT `+jobCols+` FROM bot_jobs WHERE entity_id = ? AND status = ?
			ORDER BY finished_at DESC LIMIT 1`, b.EntityID, string(status)))
		if errors.Is(err, sql.ErrNoRows) {
			return nil, nil
		}
		return &j, err
	}
	var err error
	if b.LastJobOK, err = last(JobSuccess); err != nil {
		return err
	}
	if b.LastJobFailed, err = last(JobFailed); err != nil {
		return err
	}
	since := ms(s.now().Add(-24 * time.Hour))
	return s.db.QueryRowContext(ctx, `SELECT
		(SELECT COUNT(*) FROM bot_jobs WHERE entity_id = ?1 AND status = 'success' AND finished_at >= ?2),
		(SELECT COUNT(*) FROM bot_jobs WHERE entity_id = ?1 AND status = 'failed' AND finished_at >= ?2),
		(SELECT COUNT(*) FROM bot_jobs WHERE entity_id = ?1 AND status IN ('running','pending'))`, b.EntityID, since).
		Scan(&b.Jobs.Success24h, &b.Jobs.Failed24h, &b.Jobs.Running)
}

// PruneResult reports what retention removed.
type PruneResult struct {
	Jobs    int64 `json:"jobs"`
	Actions int64 `json:"actions"`
}

// Prune applies job and audit retention (age, then a global row cap).
func (s *Service) Prune(ctx context.Context) (PruneResult, error) {
	var r PruneResult
	now := s.now()
	res, err := s.db.ExecContext(ctx, `DELETE FROM bot_jobs WHERE updated_at < ? AND status NOT IN ('running','pending')`,
		ms(now.Add(-time.Duration(s.cfg.JobRetentionDays)*24*time.Hour)))
	if err != nil {
		return r, err
	}
	r.Jobs, _ = res.RowsAffected()
	res, err = s.db.ExecContext(ctx, `DELETE FROM bot_jobs WHERE id IN (SELECT id FROM bot_jobs ORDER BY updated_at DESC LIMIT -1 OFFSET ?)`, s.cfg.JobMaxRows)
	if err != nil {
		return r, err
	}
	n, _ := res.RowsAffected()
	r.Jobs += n
	res, err = s.db.ExecContext(ctx, `DELETE FROM bot_actions WHERE requested_at < ? AND status != 'running'`,
		ms(now.Add(-time.Duration(s.cfg.AuditRetentionDays)*24*time.Hour)))
	if err != nil {
		return r, err
	}
	r.Actions, _ = res.RowsAffected()
	return r, nil
}
