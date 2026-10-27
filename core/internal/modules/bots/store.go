package bots

import "aerhome/core/internal/foundation/storage"

// Tables owned by Bots. Times are Unix milliseconds (UTC).
var migrations = []storage.Migration{
	{Version: 1, Name: "create_bots", SQL: `
CREATE TABLE bot_configs (
	entity_id          TEXT PRIMARY KEY,
	runtime            TEXT NOT NULL,
	category           TEXT NOT NULL DEFAULT '',
	controller_id      TEXT NOT NULL DEFAULT '',
	n8n_instance_id    TEXT NOT NULL DEFAULT '',
	n8n_workflow_ids   TEXT NOT NULL DEFAULT '[]',
	telegram_token_id  TEXT NOT NULL DEFAULT '',
	container          TEXT NOT NULL DEFAULT '',
	heartbeat_interval INTEGER NOT NULL,
	heartbeat_timeout  INTEGER NOT NULL,
	log_source         TEXT NOT NULL,
	notes              TEXT NOT NULL DEFAULT '',
	revision           INTEGER NOT NULL DEFAULT 1,
	created_at         INTEGER NOT NULL,
	updated_at         INTEGER NOT NULL
);

CREATE TABLE bot_jobs (
	id          TEXT PRIMARY KEY,
	entity_id   TEXT NOT NULL,
	external_id TEXT NOT NULL,
	name        TEXT NOT NULL,
	status      TEXT NOT NULL,
	source      TEXT NOT NULL,
	started_at  INTEGER,
	finished_at INTEGER,
	duration_ms INTEGER,
	result      TEXT NOT NULL DEFAULT '',
	error       TEXT NOT NULL DEFAULT '',
	retryable   INTEGER NOT NULL DEFAULT 0,
	retry_of    TEXT NOT NULL DEFAULT '',
	updated_at  INTEGER NOT NULL
);
CREATE UNIQUE INDEX bot_jobs_ext ON bot_jobs(entity_id, external_id);
CREATE INDEX bot_jobs_entity ON bot_jobs(entity_id, updated_at);
CREATE INDEX bot_jobs_status ON bot_jobs(entity_id, status, finished_at);
CREATE INDEX bot_jobs_updated ON bot_jobs(updated_at);

-- Audit of management actions; the idempotency key makes repeats harmless.
CREATE TABLE bot_actions (
	id              TEXT PRIMARY KEY,
	entity_id       TEXT NOT NULL,
	action          TEXT NOT NULL,
	job_id          TEXT NOT NULL DEFAULT '',
	adapter         TEXT NOT NULL DEFAULT '',
	status          TEXT NOT NULL,
	message         TEXT NOT NULL DEFAULT '',
	idempotency_key TEXT NOT NULL UNIQUE,
	requested_at    INTEGER NOT NULL,
	finished_at     INTEGER
);
CREATE INDEX bot_actions_entity ON bot_actions(entity_id, requested_at);
`},
}
