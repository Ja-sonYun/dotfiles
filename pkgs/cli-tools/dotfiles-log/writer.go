package main

import (
	"bytes"
	"os"
	"path/filepath"
)

type writer struct {
	file *os.File
	size int64
	cfg  settings
}

func openWriter(cfg settings) (*writer, error) {
	if err := os.MkdirAll(filepath.Dir(cfg.File), 0700); err != nil {
		return nil, err
	}
	file, err := os.OpenFile(cfg.File, os.O_CREATE|os.O_RDWR|os.O_APPEND, 0600)
	if err != nil {
		return nil, err
	}
	info, err := file.Stat()
	if err != nil {
		file.Close()
		return nil, err
	}
	return &writer{file: file, size: info.Size(), cfg: cfg}, nil
}

func (w *writer) append(data []byte) error {
	if w.size+int64(len(data)) <= int64(w.cfg.MaxBytes) {
		n, err := w.file.Write(data)
		if err != nil {
			// Roll back a partial append before the service restarts.
			if truncateErr := w.file.Truncate(w.size); truncateErr != nil {
				return truncateErr
			}
			return err
		}
		w.size += int64(n)
		return nil
	}

	// Keep headroom so reaching the limit does not force a rewrite for every event.
	keep := min(int64(w.cfg.MaxBytes/2), int64(w.cfg.MaxBytes-len(data)), w.size)
	retained := make([]byte, keep)
	if keep > 0 {
		if _, err := w.file.ReadAt(retained, w.size-keep); err != nil {
			return err
		}
		if keep < w.size {
			if newline := bytes.IndexByte(retained, '\n'); newline >= 0 {
				retained = retained[newline+1:]
			} else {
				retained = nil
			}
		}
	}
	info, err := w.file.Stat()
	if err != nil {
		return err
	}
	replacement, err := os.CreateTemp(filepath.Dir(w.cfg.File), ".dotfiles-log-*")
	if err != nil {
		return err
	}
	defer os.Remove(replacement.Name())
	installed := false
	defer func() {
		if !installed {
			replacement.Close()
		}
	}()
	if err = replacement.Chmod(info.Mode().Perm()); err != nil {
		return err
	}
	contents := append(retained, data...)
	if _, err = replacement.Write(contents); err != nil {
		return err
	}
	if err = os.Rename(replacement.Name(), w.cfg.File); err != nil {
		return err
	}
	w.file.Close()
	w.file = replacement
	w.size = int64(len(contents))
	installed = true
	return nil
}
