package main

import "syscall"

func watchChild(pid int) error {
	queue, err := syscall.Kqueue()
	if err != nil {
		return err
	}
	defer syscall.Close(queue)
	var event syscall.Kevent_t
	syscall.SetKevent(&event, pid, syscall.EVFILT_PROC, syscall.EV_ADD|syscall.EV_ONESHOT)
	event.Fflags = syscall.NOTE_EXIT
	_, err = syscall.Kevent(queue, []syscall.Kevent_t{event}, nil, nil)
	if err == syscall.ESRCH {
		return nil
	}
	if err != nil {
		return err
	}
	events := make([]syscall.Kevent_t, 1)
	for {
		count, err := syscall.Kevent(queue, nil, events, nil)
		if err == syscall.EINTR {
			continue
		}
		if err != nil {
			return err
		}
		if count > 0 {
			if events[0].Flags&syscall.EV_ERROR != 0 {
				return syscall.Errno(events[0].Data)
			}
			return nil
		}
	}
}
