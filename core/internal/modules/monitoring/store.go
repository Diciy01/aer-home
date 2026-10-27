package monitoring

import "aerhome/core/internal/foundation/storage"

// Tables owned by Monitoring. Times are Unix milliseconds (UTC) so range
// queries and retention are plain integer comparisons on indexes.
var migrations = []storage.Migration{
	{Version: 1, Name: "create_monitoring", SQL: `
CREATE TABLE mon_agents (
	id           TEXT PRIMARY KEY,
	entity_id    TEXT NOT NULL,
	name         TEXT NOT NULL,
	kind         TEXT NOT NULL,
	secret_hash  BLOB NOT NULL,
	created_at   INTEGER NOT NULL,
	revoked_at   INTEGER,
	last_seen_at INTEGER,
	info         TEXT,
	bot          TEXT
);
CREATE INDEX mon_agents_entity ON mon_agents(entity_id);

-- Raw samples (short retention). Null value = explained absence.
CREATE TABLE mon_samples (
	entity_id TEXT NOT NULL,
	metric    TEXT NOT NULL,
	label     TEXT NOT NULL,
	ts        INTEGER NOT NULL,
	value     REAL,
	quality   TEXT NOT NULL,
	PRIMARY KEY (entity_id, metric, label, ts)
) WITHOUT ROWID;
CREATE INDEX mon_samples_ts ON mon_samples(ts);

-- 5-minute aggregates, maintained on write (long retention).
CREATE TABLE mon_rollups (
	entity_id TEXT NOT NULL,
	metric    TEXT NOT NULL,
	label     TEXT NOT NULL,
	bucket    INTEGER NOT NULL,
	n         INTEGER NOT NULL,
	sum       REAL NOT NULL,
	min       REAL NOT NULL,
	max       REAL NOT NULL,
	PRIMARY KEY (entity_id, metric, label, bucket)
) WITHOUT ROWID;
CREATE INDEX mon_rollups_bucket ON mon_rollups(bucket);

-- Latest value per series (current state, never pruned by age).
CREATE TABLE mon_latest (
	entity_id TEXT NOT NULL,
	metric    TEXT NOT NULL,
	label     TEXT NOT NULL,
	ts        INTEGER NOT NULL,
	value     REAL,
	quality   TEXT NOT NULL,
	reason    TEXT NOT NULL,
	source    TEXT NOT NULL,
	PRIMARY KEY (entity_id, metric, label)
) WITHOUT ROWID;

CREATE TABLE mon_state (
	entity_id      TEXT PRIMARY KEY,
	status         TEXT NOT NULL,
	reason         TEXT NOT NULL,
	check_kind     TEXT NOT NULL,
	last_contact   INTEGER,
	last_check     INTEGER,
	changed_at     INTEGER,
	failures       INTEGER NOT NULL DEFAULT 0,
	ever_reachable INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE mon_logs (
	id             INTEGER PRIMARY KEY AUTOINCREMENT,
	ts             INTEGER NOT NULL,
	entity_id      TEXT,
	source         TEXT NOT NULL,
	level          INTEGER NOT NULL,
	message        TEXT NOT NULL,
	correlation_id TEXT NOT NULL DEFAULT '',
	fields         TEXT,
	incident_id    TEXT
);
CREATE INDEX mon_logs_ts ON mon_logs(ts);
CREATE INDEX mon_logs_entity ON mon_logs(entity_id, ts);
CREATE INDEX mon_logs_level ON mon_logs(level, ts);

CREATE TABLE mon_incidents (
	id              TEXT PRIMARY KEY,
	key             TEXT NOT NULL,
	title           TEXT NOT NULL,
	source          TEXT NOT NULL,
	entity_id       TEXT,
	severity        TEXT NOT NULL,
	status          TEXT NOT NULL,
	opened_at       INTEGER NOT NULL,
	updated_at      INTEGER NOT NULL,
	acknowledged_at INTEGER,
	resolved_at     INTEGER,
	cause           TEXT NOT NULL DEFAULT '',
	related         TEXT NOT NULL DEFAULT '[]',
	occurrences     INTEGER NOT NULL DEFAULT 1,
	last_message    TEXT NOT NULL DEFAULT ''
);
-- At most one unresolved incident per key: repeats are grouped into it.
CREATE UNIQUE INDEX mon_incidents_active_key ON mon_incidents(key) WHERE status != 'resolved';
CREATE INDEX mon_incidents_entity ON mon_incidents(entity_id, opened_at);
CREATE INDEX mon_incidents_status ON mon_incidents(status, opened_at);

CREATE TABLE mon_incident_events (
	incident_id TEXT NOT NULL REFERENCES mon_incidents(id) ON DELETE CASCADE,
	ts          INTEGER NOT NULL,
	kind        TEXT NOT NULL,
	message     TEXT NOT NULL
);
CREATE INDEX mon_incident_events_inc ON mon_incident_events(incident_id, ts);

CREATE TABLE mon_events (
	id          INTEGER PRIMARY KEY AUTOINCREMENT,
	ts          INTEGER NOT NULL,
	entity_id   TEXT,
	kind        TEXT NOT NULL,
	severity    TEXT NOT NULL,
	message     TEXT NOT NULL,
	incident_id TEXT
);
CREATE INDEX mon_events_ts ON mon_events(ts);
CREATE INDEX mon_events_entity ON mon_events(entity_id, ts);

CREATE TABLE mon_notifications (
	id          TEXT PRIMARY KEY,
	ts          INTEGER NOT NULL,
	kind        TEXT NOT NULL,
	severity    TEXT NOT NULL,
	title       TEXT NOT NULL,
	body        TEXT NOT NULL,
	entity_id   TEXT,
	incident_id TEXT,
	read_at     INTEGER,
	telegram    TEXT NOT NULL
);
CREATE INDEX mon_notifications_ts ON mon_notifications(ts);

-- Last known Docker containers (also survives Docker going away).
CREATE TABLE mon_containers (
	id         TEXT PRIMARY KEY,
	name       TEXT NOT NULL,
	data       TEXT NOT NULL,
	changed_at INTEGER NOT NULL,
	seen_at    INTEGER NOT NULL
);
`},
	// v2 (M06): a bot's log page filters by entity and orders by id; without
	// this index SQLite sorts every row of the entity (148 ms at 50k lines).
	{Version: 2, Name: "logs_entity_id_index", SQL: `CREATE INDEX mon_logs_entity_id ON mon_logs(entity_id, id)`},
}
