package power

import "aerhome/core/internal/foundation/storage"

// Tables owned by Power. Times are Unix milliseconds (UTC). Device
// identity lives in Registry; status lives in Monitoring.
var migrations = []storage.Migration{
	{Version: 1, Name: "create_power", SQL: `
CREATE TABLE power_wol (
	entity_id  TEXT PRIMARY KEY,
	mac        TEXT NOT NULL,
	broadcast  TEXT NOT NULL,
	iface      TEXT NOT NULL DEFAULT '',
	port       INTEGER NOT NULL DEFAULT 0,
	updated_at INTEGER NOT NULL
);

CREATE TABLE power_policies (
	entity_id      TEXT PRIMARY KEY,
	enabled        INTEGER NOT NULL,
	wake           INTEGER NOT NULL,
	shutdown       INTEGER NOT NULL,
	reboot         INTEGER NOT NULL,
	suspend        INTEGER NOT NULL,
	switch_os      INTEGER NOT NULL,
	allow_bitlocker INTEGER NOT NULL,
	revision       INTEGER NOT NULL DEFAULT 1,
	updated_at     INTEGER NOT NULL
);

-- One row per power agent (a dual-boot PC has one agent per OS).
CREATE TABLE power_hosts (
	agent_id   TEXT PRIMARY KEY,
	entity_id  TEXT NOT NULL,
	info       TEXT NOT NULL,
	boot_id    TEXT NOT NULL DEFAULT '',
	last_hello INTEGER NOT NULL
);
CREATE INDEX power_hosts_entity ON power_hosts(entity_id);

CREATE TABLE power_jobs (
	id              TEXT PRIMARY KEY,
	entity_id       TEXT NOT NULL,
	action          TEXT NOT NULL,
	target_os       TEXT NOT NULL DEFAULT '',
	entry_id        TEXT NOT NULL DEFAULT '',
	state           TEXT NOT NULL,
	message         TEXT NOT NULL DEFAULT '',
	idempotency_key TEXT NOT NULL UNIQUE,
	simulated       INTEGER NOT NULL DEFAULT 0,
	from_os         TEXT NOT NULL DEFAULT '',
	from_boot_id    TEXT NOT NULL DEFAULT '',
	went_offline    INTEGER NOT NULL DEFAULT 0,
	requested_at    INTEGER NOT NULL,
	sent_at         INTEGER,
	exec_at         INTEGER,
	finished_at     INTEGER,
	deadline        INTEGER NOT NULL
);
CREATE INDEX power_jobs_entity ON power_jobs(entity_id, requested_at);
CREATE INDEX power_jobs_state ON power_jobs(state);

CREATE TABLE power_events (
	id     INTEGER PRIMARY KEY AUTOINCREMENT,
	job_id TEXT NOT NULL,
	ts     INTEGER NOT NULL,
	kind   TEXT NOT NULL,
	message TEXT NOT NULL
);
CREATE INDEX power_events_job ON power_events(job_id, id);
`},
}
