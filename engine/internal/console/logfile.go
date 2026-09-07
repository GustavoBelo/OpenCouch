package console

import (
	"errors"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"time"
)

// The wrapper's log, and the logins that came before it.
//
// One file per login rather than one per switch: the wrapper lives the whole
// login and the trips between the desktop and the console happen inside it, so
// a login is the unit a person recognises -- "the time I tried to play last
// night" -- and the failure worth reading is almost always in the one before
// this.
const (
	logFile    = "console.log"
	logDirName = "logs"
	// logsKept is how many logins are worth keeping. The log is the only
	// account of a session that ended badly, and it is a few kilobytes; ten is
	// more history than anyone reads and still nothing to a disk.
	logsKept = 10
)

// logID is the shape of a kept login's name. It is checked rather than trusted
// because the id arrives from outside: it comes back from `log --list` through
// the graphical app, and joining an unchecked one to a path is how a caller
// reads whatever it likes.
var logID = regexp.MustCompile(`^[0-9]{8}-[0-9]{6}$`)

func LogPath(stateDir string) string { return filepath.Join(stateDir, logFile) }

func LogDir(stateDir string) string { return filepath.Join(stateDir, logDirName) }

// LogSession is one kept login, as the app lists them.
type LogSession struct {
	ID   string `json:"id"`
	Name string `json:"name"`
	When string `json:"when"`
}

// ReadLog returns the log of the login running now.
//
// A missing file is not an error: on a machine that has never hosted a session
// there is nothing to say, and reporting that as a failure would put an error
// banner in front of a user whose only mistake was opening the panel early.
func ReadLog(stateDir string) (string, error) {
	data, err := os.ReadFile(LogPath(stateDir))
	if errors.Is(err, os.ErrNotExist) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// ClearLog empties the current log without removing the file, so the handle the
// running wrapper already holds keeps writing to something.
func ClearLog(stateDir string) error {
	err := os.Truncate(LogPath(stateDir), 0)
	if errors.Is(err, os.ErrNotExist) {
		return nil
	}
	return err
}

// RotateLog files the current log away under the time it was last written, and
// drops the oldest once there are more than logsKept.
//
// Called at the top of `host-session`, which is the one moment a login begins.
func RotateLog(stateDir string) error {
	path := LogPath(stateDir)
	info, err := os.Stat(path)
	if errors.Is(err, os.ErrNotExist) || (err == nil && info.Size() == 0) {
		return nil
	}
	if err != nil {
		return err
	}
	dir := LogDir(stateDir)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return err
	}
	// Named for when it was last written, not for now: this file belongs to the
	// login that just ended, and dating it by the login that is starting would
	// put every archive an unbounded distance from what is in it.
	name := info.ModTime().Format("20060102-150405")
	if err := os.Rename(path, filepath.Join(dir, name+".log")); err != nil {
		return err
	}
	return pruneLogs(dir)
}

func pruneLogs(dir string) error {
	kept, err := keptLogs(dir)
	if err != nil {
		return err
	}
	for _, session := range kept[min(len(kept), logsKept):] {
		_ = os.Remove(filepath.Join(dir, session.ID+".log"))
	}
	return nil
}

// LogSessions lists the logins kept, newest first.
func LogSessions(stateDir string) ([]LogSession, error) {
	kept, err := keptLogs(LogDir(stateDir))
	if err != nil {
		return nil, err
	}
	return kept, nil
}

// ReadLogSession returns one kept login by id.
func ReadLogSession(stateDir, id string) (string, error) {
	if !logID.MatchString(id) {
		return "", errors.New("no log by that name")
	}
	data, err := os.ReadFile(filepath.Join(LogDir(stateDir), id+".log"))
	if errors.Is(err, os.ErrNotExist) {
		return "", errors.New("no log by that name")
	}
	if err != nil {
		return "", err
	}
	return string(data), nil
}

// keptLogs reads the archive directory, newest first. A directory that is not
// there yet is an empty list, not a failure -- the slice is non-nil because it
// is encoded as JSON for the app, and `null` is not a list it can iterate.
func keptLogs(dir string) ([]LogSession, error) {
	sessions := []LogSession{}
	entries, err := os.ReadDir(dir)
	if errors.Is(err, os.ErrNotExist) {
		return sessions, nil
	}
	if err != nil {
		return nil, err
	}
	for _, entry := range entries {
		if entry.IsDir() || !strings.HasSuffix(entry.Name(), ".log") {
			continue
		}
		id := strings.TrimSuffix(entry.Name(), ".log")
		if !logID.MatchString(id) {
			continue
		}
		when, err := time.ParseInLocation("20060102-150405", id, time.Local)
		if err != nil {
			continue
		}
		sessions = append(sessions, LogSession{
			ID:   id,
			Name: when.Format("2006-01-02 15:04"),
			When: when.Format(time.RFC3339),
		})
	}
	sort.Slice(sessions, func(i, j int) bool { return sessions[i].ID > sessions[j].ID })
	return sessions, nil
}
