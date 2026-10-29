package remote

import "aerhome/core/internal/foundation/storage"

// Tables owned by Remote. Times are Unix milliseconds (UTC). Passwords,
// file tokens and tunnel tickets are never stored: they live in memory
// until handed over. Client credentials and pairing codes: SHA-256 only.
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
`}, {Version: 2, Name: "remote_clients_relay", SQL: `
CREATE TABLE remote_clients (
	id           TEXT PRIMARY KEY,
	name         TEXT NOT NULL,
	hosts        TEXT NOT NULL,
	clipboard    INTEGER NOT NULL,
	files        INTEGER NOT NULL,
	secret_hash  BLOB,
	pair_hash    BLOB UNIQUE,
	pair_expires INTEGER,
	device_name  TEXT NOT NULL DEFAULT '',
	created_at   INTEGER NOT NULL,
	paired_at    INTEGER,
	last_seen_at INTEGER,
	last_addr    TEXT NOT NULL DEFAULT '',
	revoked_at   INTEGER
);

ALTER TABLE remote_sessions ADD COLUMN route TEXT NOT NULL DEFAULT 'direct';
CREATE INDEX remote_sessions_client ON remote_sessions(client_id, created_at);
`}, {Version: 3, Name: "remote_connect_devices", SQL: `
CREATE TABLE remote_enrollments (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	code_hash  BLOB UNIQUE,
	max_uses   INTEGER NOT NULL,
	uses       INTEGER NOT NULL DEFAULT 0,
	expires_at INTEGER NOT NULL,
	created_at INTEGER NOT NULL,
	revoked_at INTEGER
);

CREATE TABLE remote_devices (
	id            TEXT PRIMARY KEY,
	number        TEXT NOT NULL UNIQUE,
	name          TEXT NOT NULL,
	entity_id     TEXT NOT NULL UNIQUE,
	agent_id      TEXT NOT NULL UNIQUE,
	client_id     TEXT NOT NULL UNIQUE,
	box_pub       TEXT NOT NULL,
	instance      TEXT NOT NULL,
	enrollment_id TEXT NOT NULL DEFAULT '',
	created_at    INTEGER NOT NULL,
	last_seen_at  INTEGER,
	conflict_at   INTEGER,
	revoked_at    INTEGER
);

ALTER TABLE remote_sessions ADD COLUMN auth_state TEXT NOT NULL DEFAULT '';
`},
	{Version: 4, Name: "remote_device_trust", SQL: `
ALTER TABLE remote_devices ADD COLUMN unattended_enabled INTEGER NOT NULL DEFAULT 0;
CREATE TABLE remote_device_trust (
 target_id TEXT NOT NULL REFERENCES remote_devices(id),
 viewer_id TEXT NOT NULL REFERENCES remote_devices(id),
 box_pub TEXT NOT NULL,
 revision INTEGER NOT NULL DEFAULT 1,
 created_at INTEGER NOT NULL,
 revoked_at INTEGER,
 PRIMARY KEY (target_id, viewer_id)
);
ALTER TABLE remote_sessions ADD COLUMN trust_revision INTEGER NOT NULL DEFAULT 0;
`},
}
