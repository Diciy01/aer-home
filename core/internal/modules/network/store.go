package network

import "aerhome/core/internal/foundation/storage"

// Network keeps only the current state of its own checks; history, logs
// and incidents live in Monitoring.
var migrations = []storage.Migration{
	{Version: 1, Name: "create_network", SQL: `
CREATE TABLE net_checks (
	key        TEXT PRIMARY KEY,
	kind       TEXT NOT NULL,
	name       TEXT NOT NULL,
	entity_id  TEXT NOT NULL DEFAULT '',
	status     TEXT NOT NULL,
	reason     TEXT NOT NULL,
	latency_ms REAL,
	details    TEXT NOT NULL DEFAULT '{}',
	failures   INTEGER NOT NULL DEFAULT 0,
	last_check INTEGER,
	last_ok    INTEGER,
	changed_at INTEGER,
	last_log   INTEGER
);
`},
}
