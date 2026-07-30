// Command sqlite-backup-helper creates a verified, consistent SQLite snapshot.
//
// It is built locally for the target Fly Machine architecture and copied to the
// remote /tmp directory by fly-backup-data.sh. Keeping it outside the service
// image lets the backup workflow work without a production deployment or an
// interactive package installation on the Machine.
package main

import (
	"database/sql"
	"errors"
	"fmt"
	"os"
	"strings"

	_ "modernc.org/sqlite"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "Usage: %s <source-db> <destination-db>\\n", os.Args[0])
		os.Exit(2)
	}

	if err := snapshot(os.Args[1], os.Args[2]); err != nil {
		fmt.Fprintf(os.Stderr, "SQLite snapshot failed: %v\\n", err)
		os.Exit(1)
	}
}

// snapshot creates destination as a consistent point-in-time copy of source.
// VACUUM INTO never changes the source database; a busy timeout avoids failing
// immediately when the running service briefly holds a SQLite lock.
func snapshot(source, destination string) error {
	if source == destination {
		return errors.New("source and destination must differ")
	}
	if _, err := os.Stat(source); err != nil {
		return fmt.Errorf("source database: %w", err)
	}
	if _, err := os.Stat(destination); err == nil {
		return fmt.Errorf("destination already exists: %s", destination)
	} else if !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("inspect destination: %w", err)
	}

	db, err := sql.Open("sqlite", source)
	if err != nil {
		return fmt.Errorf("open source: %w", err)
	}
	defer db.Close()
	db.SetMaxOpenConns(1)

	if _, err := db.Exec("PRAGMA busy_timeout = 30000"); err != nil {
		return fmt.Errorf("set source busy timeout: %w", err)
	}
	if _, err := db.Exec("VACUUM INTO " + sqliteString(destination)); err != nil {
		return fmt.Errorf("VACUUM INTO: %w", err)
	}

	return integrityCheck(destination)
}

// integrityCheck rejects a truncated or otherwise invalid snapshot before the
// shell script archives it. The check is performed only against the temporary
// destination and never writes to the original database.
func integrityCheck(path string) error {
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return fmt.Errorf("open snapshot: %w", err)
	}
	defer db.Close()

	var result string
	if err := db.QueryRow("PRAGMA integrity_check").Scan(&result); err != nil {
		return fmt.Errorf("integrity_check: %w", err)
	}
	if result != "ok" {
		return fmt.Errorf("integrity_check returned %q", result)
	}
	return nil
}

// sqliteString quotes a filesystem path as one SQLite string literal. Inputs
// originate from the backup script, but quoting still keeps paths with spaces
// or apostrophes valid and prevents SQL syntax injection.
func sqliteString(value string) string {
	return "'" + strings.ReplaceAll(value, "'", "''") + "'"
}
