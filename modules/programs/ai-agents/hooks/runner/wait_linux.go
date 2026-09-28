package main

import (
	"syscall"
	"unsafe"
)

func watchChild(pid int) error {
	var info [16]uint64
	for {
		// WNOWAIT observes termination without releasing the process-group ID.
		// https://man7.org/linux/man-pages/man2/waitid.2.html
		_, _, err := syscall.Syscall6(syscall.SYS_WAITID, 1, uintptr(pid), uintptr(unsafe.Pointer(&info[0])), syscall.WEXITED|syscall.WNOWAIT, 0, 0)
		if err == syscall.EINTR {
			continue
		}
		if err != 0 {
			return err
		}
		return nil
	}
}
