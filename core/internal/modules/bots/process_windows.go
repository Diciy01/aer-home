//go:build windows

package bots

import (
	"errors"
	"os"
	"os/exec"
	"sync"
	"syscall"
	"unsafe"

	"golang.org/x/sys/windows"
)

// A private, unnamed job contains only this Core-owned child and descendants.
// Start suspended so no descendant can escape before assignment. Closing Core
// also closes the job handle and terminates the tree, without PID-based kills.
func startChild(cmd *exec.Cmd) (processControl, error) {
	job, err := windows.CreateJobObject(nil, nil)
	if err != nil {
		return processControl{}, err
	}
	info := windows.JOBOBJECT_EXTENDED_LIMIT_INFORMATION{}
	info.BasicLimitInformation.LimitFlags = windows.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
	if _, err := windows.SetInformationJobObject(job, windows.JobObjectExtendedLimitInformation,
		uintptr(unsafe.Pointer(&info)), uint32(unsafe.Sizeof(info))); err != nil {
		windows.CloseHandle(job)
		return processControl{}, err
	}
	cmd.SysProcAttr = &syscall.SysProcAttr{CreationFlags: windows.CREATE_SUSPENDED, HideWindow: true}
	if err := cmd.Start(); err != nil {
		windows.CloseHandle(job)
		return processControl{}, err
	}
	process, err := windows.OpenProcess(windows.PROCESS_SET_QUOTA|windows.PROCESS_TERMINATE|windows.SYNCHRONIZE, false, uint32(cmd.Process.Pid))
	fail := func(err error) (processControl, error) {
		_ = cmd.Process.Kill()
		_ = cmd.Wait()
		windows.CloseHandle(job)
		if process != 0 {
			windows.CloseHandle(process)
		}
		return processControl{}, err
	}
	if err != nil {
		return fail(err)
	}
	if err := windows.AssignProcessToJobObject(job, process); err != nil {
		return fail(err)
	}
	if err := resumeChild(uint32(cmd.Process.Pid)); err != nil {
		return fail(err)
	}
	var mu sync.Mutex
	stop := func() error {
		mu.Lock()
		defer mu.Unlock()
		if job == 0 {
			return os.ErrProcessDone
		}
		return windows.TerminateJobObject(job, 1)
	}
	exited := make(chan struct{})
	go func() {
		_, _ = windows.WaitForSingleObject(process, windows.INFINITE)
		// A child may exit naturally leaving descendants with inherited pipes.
		// End its private job before the output readers wait for EOF.
		_ = stop()
		windows.CloseHandle(process)
		close(exited)
	}()
	return processControl{terminate: stop, kill: stop, cleanup: func() {
		<-exited
		mu.Lock()
		defer mu.Unlock()
		windows.CloseHandle(job)
		job = 0
	}}, nil
}

func resumeChild(pid uint32) error {
	snapshot, err := windows.CreateToolhelp32Snapshot(windows.TH32CS_SNAPTHREAD, 0)
	if err != nil {
		return err
	}
	defer windows.CloseHandle(snapshot)
	entry := windows.ThreadEntry32{Size: uint32(unsafe.Sizeof(windows.ThreadEntry32{}))}
	for err := windows.Thread32First(snapshot, &entry); err == nil; err = windows.Thread32Next(snapshot, &entry) {
		if entry.OwnerProcessID != pid {
			continue
		}
		thread, err := windows.OpenThread(windows.THREAD_SUSPEND_RESUME, false, entry.ThreadID)
		if err != nil {
			return err
		}
		_, err = windows.ResumeThread(thread)
		windows.CloseHandle(thread)
		return err
	}
	return errors.New("suspended child thread not found")
}
