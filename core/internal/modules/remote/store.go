package remote

import "aerhome/core/internal/foundation/storage"

// Tables owned by Remote. Times are Unix milliseconds (UTC). Passwords and
// file tokens are never stored: they live in memory until handed over.
var migrations = []storage.Migration{
	{Version: 1, Name: "create_remote", SQL: `
CREATE TABLE remote_hosts (
	entity_id  TEXT PRIMARY KEY,
	agent_id   TEXT NOT NULL,
	info       TEXT NOT NULL,
	cert_fp    TEXT NOT NULL DEFAULT '',
	last_hello INTEGER NOT NULL
);

CREATE TABLE remote_policies (
	entity_id   TEXT PRIMARY KEY,
	enabled     INTEGER NOT NULL,
	desktop     INTEGER NOT NULL,
	clipboard   INTEGER NOT NULL,
	files       INTEGER NOT NULL,
	max_minutes INTEGER NOT NULL,
	revision    INTEGER NOT NULL DEFAULT 1,
	updated_at  INTEGER NOT NULL
);

CREATE TABLE remote_sessions (
	id              TEXT PRIMARY KEY,
	entity_id       TEXT NOT NULL,
	kind            TEXT NOT NULL,
	source_name     TEXT NOT NULL DEFAULT '',
	source_entity   TEXT NOT NULL DEFAULT '',
	client_id       TEXT NOT NULL DEFAULT '',
	transport       TEXT NOT NULL,
	state           TEXT NOT NULL,
	reason          TEXT NOT NULL DEFAULT '',
	allowed         TEXT NOT NULL,
	idempotency_key TEXT UNIQUE,
	created_at      INTEGER NOT NULL,
	approved_at     INTEGER,
	ready_at        INTEGER,
	granted_at      INTEGER,
	connected_at    INTEGER,
	lost_at         INTEGER,
	ended_at        INTEGER,
	expires_at      INTEGER NOT NULL
);
CREATE INDEX remote_sessions_entity ON remote_sessions(entity_id, created_at);
CREATE INDEX remote_sessions_state ON remote_sessions(state);

CREATE TABLE remote_events (
	id         INTEGER PRIMARY KEY AUTOINCREMENT,
	session_id TEXT NOT NULL,
	ts         INTEGER NOT NULL,
	kind       TEXT NOT NULL,
	message    TEXT NOT NULL
);
CREATE INDEX remote_events_session ON remote_events(session_id, id);
`},
}
