-- Vision One share pages: what viewers send back. Lives in the creator's
-- own Cloudflare D1 database. No names beyond what a viewer types on a
-- note, no IP addresses, no cookies.
CREATE TABLE IF NOT EXISTS pages (
  slug TEXT PRIMARY KEY,
  title TEXT,
  published_at TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS events (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  page TEXT NOT NULL,
  visit TEXT NOT NULL,
  kind TEXT NOT NULL,
  at REAL,
  emoji TEXT,
  text TEXT,
  time TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS events_page_time ON events (page, time);

CREATE TABLE IF NOT EXISTS notes (
  id TEXT PRIMARY KEY,
  page TEXT NOT NULL,
  name TEXT,
  text TEXT NOT NULL,
  at REAL NOT NULL,
  quote TEXT,
  created_at TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS notes_page_time ON notes (page, created_at);
