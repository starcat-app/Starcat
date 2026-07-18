package main

import (
	"database/sql"
	"path/filepath"
	"testing"

	_ "modernc.org/sqlite"
)

// TestSnapshot verifies that the helper produces a readable copy without
// requiring a stopped source database or the sqlite3 command-line binary.
func TestSnapshot(t *testing.T) {
	source := filepath.Join(t.TempDir(), "source.db")
	destination := filepath.Join(t.TempDir(), "snapshot.db")

	db, err := sql.Open("sqlite", source)
	if err != nil {
		t.Fatalf("open source: %v", err)
	}
	defer db.Close()

	var journalMode string
	if err := db.QueryRow("PRAGMA journal_mode = WAL").Scan(&journalMode); err != nil {
		t.Fatalf("enable WAL: %v", err)
	}
	if journalMode != "wal" {
		t.Fatalf("journal mode = %q, want wal", journalMode)
	}
	if _, err := db.Exec("CREATE TABLE repos (id INTEGER PRIMARY KEY, name TEXT NOT NULL)"); err != nil {
		t.Fatalf("create table: %v", err)
	}
	if _, err := db.Exec("INSERT INTO repos(name) VALUES ('starcat')"); err != nil {
		t.Fatalf("insert row: %v", err)
	}

	// 保持源库连接和 WAL 文件处于活动状态，模拟线上服务仍在运行的备份时刻。
	if err := snapshot(source, destination); err != nil {
		t.Fatalf("snapshot: %v", err)
	}

	backup, err := sql.Open("sqlite", destination)
	if err != nil {
		t.Fatalf("open snapshot: %v", err)
	}
	defer backup.Close()

	var count int
	if err := backup.QueryRow("SELECT COUNT(*) FROM repos WHERE name = 'starcat'").Scan(&count); err != nil {
		t.Fatalf("read snapshot: %v", err)
	}
	if count != 1 {
		t.Fatalf("snapshot row count = %d, want 1", count)
	}
}
