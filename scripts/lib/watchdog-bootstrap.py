#!/usr/bin/env python3
"""Bound the first native-tool build using an already installed interpreter.

Normal jobs use kano-cpp-infra-tool. This bootstrap has no package dependencies;
POSIX containment covers the owned process group, not escaped sessions.
"""
import argparse
import ctypes
import os
import selectors
import shutil
import signal
import subprocess
import sys
import time

CAPTURE_LIMIT = 1048576


def windows_quoted_arg(argument):
    parts = ['"']
    backslashes = 0
    for character in argument:
        if character == "\\":
            backslashes += 1
            continue
        if character == '"':
            parts.append("\\" * (backslashes * 2 + 1))
        else:
            parts.append("\\" * backslashes)
        parts.append(character)
        backslashes = 0
    parts.append("\\" * (backslashes * 2))
    parts.append('"')
    return "".join(parts)


def windows_command_line(arguments):
    """Use the native runner's argv quoting and existing cmd payload policy.

    MSYS needs outer quotes even for quote-bearing args without whitespace.
    cmd switches and the /c or /k payload retain the native facade's special
    handling; ordinary args double backslashes before quotes and at the end.
    """
    executable = arguments[0].replace("\\", "/").rsplit("/", 1)[-1].lower()
    is_cmd = executable in ("cmd", "cmd.exe")
    quoted = [windows_quoted_arg(arguments[0])]
    for index, argument in enumerate(arguments[1:], start=1):
        if is_cmd and arguments[index - 1].lower() in ("/c", "/k"):
            quoted.append('"' + argument + '"')
        elif is_cmd and argument.startswith("/"):
            quoted.append(argument)
        else:
            quoted.append(windows_quoted_arg(argument))
    return " ".join(quoted)


def retain(buffers, stream, data):
    buffer = buffers[stream]
    remaining = max(0, CAPTURE_LIMIT - len(buffer))
    buffer.extend(data[:remaining])
    return len(data) > remaining


def run_posix(command, timeout, cleanup, buffers):
    start = time.monotonic()
    if not hasattr(os, "waitid") or not hasattr(os, "WNOWAIT"):
        raise RuntimeError("POSIX bootstrap requires waitid(WNOWAIT) to reserve the owned process-group leader")
    process = None
    selector = None
    cleanup_verified = False
    group_terminated = False
    root_reaped = False
    deadline = start + timeout
    timed_out = False
    cleanup_deadline = None
    truncated = False
    exit_code = None

    def group_alive():
        try:
            os.killpg(process.pid, 0)
            return True
        except ProcessLookupError:
            return False

    try:
        # Setup belongs to the ownership scope too: selector or nonblocking
        # setup can fail after the subprocess has already started.
        process = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, start_new_session=True)
        selector = selectors.DefaultSelector()
        for stream, pipe in enumerate((process.stdout, process.stderr)):
            os.set_blocking(pipe.fileno(), False)
            selector.register(pipe, selectors.EVENT_READ, stream)
        while True:
            now = time.monotonic()
            if not root_reaped:
                # Observe completion while reserving the leader PID. Reaping
                # before killpg could let the OS recycle it into an unrelated
                # process group during early-parent-exit cleanup.
                observed = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                if observed is not None:
                    exit_code = observed.si_status if observed.si_code == os.CLD_EXITED else -observed.si_status
            if cleanup_deadline is None and (now >= deadline or exit_code is not None):
                timed_out = now >= deadline
                cleanup_deadline = now + cleanup
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
                group_terminated = True
            if group_terminated and not root_reaped:
                try:
                    process.wait(timeout=0)
                    root_reaped = True
                except subprocess.TimeoutExpired:
                    pass
            for key, _ in selector.select(0.01):
                try:
                    data = os.read(key.fd, 65536)
                except BlockingIOError:
                    continue
                if data:
                    truncated |= retain(buffers, key.data, data)
                else:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
            if root_reaped and not group_alive() and not selector.get_map():
                cleanup_verified = True
                return (124 if timed_out else exit_code), True, truncated, time.monotonic() - start
            if cleanup_deadline is not None and time.monotonic() >= cleanup_deadline:
                # A remaining group member may be a zombie; fail rather than
                # claim verified cleanup while the OS still reports the group.
                return (124 if timed_out else 125), False, truncated, time.monotonic() - start
    finally:
        if selector is not None:
            selector.close()
        if process is not None:
            for pipe in (process.stdout, process.stderr):
                if pipe is not None and not pipe.closed:
                    pipe.close()
            if not cleanup_verified:
                if not group_terminated:
                    # The root is still unreaped on every setup failure. Send
                    # only one group kill before releasing that reserved PID.
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    group_terminated = True
                # Setup failures receive one finite cleanup budget; ordinary
                # timeout paths retain their existing shared cleanup deadline.
                final_deadline = cleanup_deadline if cleanup_deadline is not None else time.monotonic() + cleanup
                try:
                    process.wait(timeout=max(0, final_deadline - time.monotonic()))
                except subprocess.TimeoutExpired:
                    pass
                while time.monotonic() < final_deadline and group_alive():
                    time.sleep(0.01)


def run_windows(command, timeout, cleanup, buffers):
    from ctypes import wintypes as w
    kernel = ctypes.WinDLL("kernel32", use_last_error=True)
    handle = w.HANDLE
    size_t = ctypes.c_size_t

    class Security(ctypes.Structure):
        _fields_ = [("length", w.DWORD), ("descriptor", w.LPVOID), ("inherit", w.BOOL)]

    class Startup(ctypes.Structure):
        _fields_ = [("cb", w.DWORD), ("reserved", w.LPWSTR), ("desktop", w.LPWSTR),
                    ("title", w.LPWSTR), ("x", w.DWORD), ("y", w.DWORD),
                    ("xsize", w.DWORD), ("ysize", w.DWORD), ("xchars", w.DWORD),
                    ("ychars", w.DWORD), ("fill", w.DWORD), ("flags", w.DWORD),
                    ("show", w.WORD), ("reserved_size", w.WORD), ("reserved_ptr", w.LPVOID),
                    ("stdin", handle), ("stdout", handle), ("stderr", handle)]

    class ProcessInfo(ctypes.Structure):
        _fields_ = [("process", handle), ("thread", handle), ("pid", w.DWORD), ("tid", w.DWORD)]

    class BasicLimits(ctypes.Structure):
        _fields_ = [("process_time", ctypes.c_longlong), ("job_time", ctypes.c_longlong),
                    ("flags", w.DWORD), ("min_working", size_t), ("max_working", size_t),
                    ("active_limit", w.DWORD), ("affinity", size_t),
                    ("priority", w.DWORD), ("scheduling", w.DWORD)]

    class IoCounters(ctypes.Structure):
        _fields_ = [(name, ctypes.c_ulonglong) for name in
                    ("reads", "writes", "other", "read_bytes", "write_bytes", "other_bytes")]

    class ExtendedLimits(ctypes.Structure):
        _fields_ = [("basic", BasicLimits), ("io", IoCounters), ("process_memory", size_t),
                    ("job_memory", size_t), ("peak_process", size_t), ("peak_job", size_t)]

    class Accounting(ctypes.Structure):
        _fields_ = [(name, ctypes.c_longlong) for name in ("user", "kernel", "period_user", "period_kernel")] + [
            (name, w.DWORD) for name in ("faults", "total", "active", "terminated")]

    def bind(name, args, result=w.BOOL):
        function = getattr(kernel, name)
        function.argtypes = args
        function.restype = result
        return function

    close = bind("CloseHandle", [handle])
    create_job = bind("CreateJobObjectW", [w.LPVOID, w.LPCWSTR], handle)
    set_job = bind("SetInformationJobObject", [handle, ctypes.c_int, w.LPVOID, w.DWORD])
    query_job = bind("QueryInformationJobObject", [handle, ctypes.c_int, w.LPVOID, w.DWORD, w.LPVOID])
    assign_job = bind("AssignProcessToJobObject", [handle, handle])
    terminate_job = bind("TerminateJobObject", [handle, w.UINT])
    create_pipe = bind("CreatePipe", [ctypes.POINTER(handle), ctypes.POINTER(handle), w.LPVOID, w.DWORD])
    set_handle = bind("SetHandleInformation", [handle, w.DWORD, w.DWORD])
    peek_pipe = bind("PeekNamedPipe", [handle, w.LPVOID, w.DWORD, w.LPVOID, ctypes.POINTER(w.DWORD), w.LPVOID])
    read_pipe = bind("ReadFile", [handle, w.LPVOID, w.DWORD, ctypes.POINTER(w.DWORD), w.LPVOID])
    create_process = bind("CreateProcessW", [w.LPCWSTR, w.LPWSTR, w.LPVOID, w.LPVOID, w.BOOL,
                                           w.DWORD, w.LPVOID, w.LPCWSTR, w.LPVOID, w.LPVOID])
    resume = bind("ResumeThread", [handle], w.DWORD)
    get_exit = bind("GetExitCodeProcess", [handle, ctypes.POINTER(w.DWORD)])
    terminate_process = bind("TerminateProcess", [handle, w.UINT])
    wait_process = bind("WaitForSingleObject", [handle, w.DWORD], w.DWORD)
    get_std = bind("GetStdHandle", [w.DWORD], handle)
    bind("SetErrorMode", [w.UINT], w.UINT)(0x0001 | 0x0002 | 0x8000)

    def checked(ok):
        if not ok:
            raise ctypes.WinError(ctypes.get_last_error())

    job = None
    info = ProcessInfo()
    reads = []
    writes = []
    start = time.monotonic()
    assigned = False
    try:
        job = create_job(None, None)
        checked(job)
        limits = ExtendedLimits()
        limits.basic.flags = 0x2000  # JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
        checked(set_job(job, 9, ctypes.byref(limits), ctypes.sizeof(limits)))
        security = Security(ctypes.sizeof(Security), None, True)
        for _ in range(2):
            reader, writer = handle(), handle()
            checked(create_pipe(ctypes.byref(reader), ctypes.byref(writer), ctypes.byref(security), 0))
            reads.append(reader)
            writes.append(writer)
            checked(set_handle(reader, 1, 0))
        startup = Startup()
        startup.cb = ctypes.sizeof(startup)
        startup.flags = 0x100 | 0x1  # STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW
        startup.show = 0
        startup.stdin = get_std(0xFFFFFFF6)
        startup.stdout, startup.stderr = writes
        executable = shutil.which(command[0])
        if executable is None:
            raise RuntimeError("bootstrap executable was not found")
        command_line = ctypes.create_unicode_buffer(windows_command_line([executable] + command[1:]))
        checked(create_process(executable, command_line, None, None, True, 0x4 | 0x08000000,
                               None, None, ctypes.byref(startup), ctypes.byref(info)))
        checked(assign_job(job, info.process))
        assigned = True
        if resume(info.thread) == 0xFFFFFFFF:
            checked(False)
        close(info.thread)
        info.thread = None
        for writer in writes:
            close(writer)
        writes.clear()
        deadline = start + timeout
        cleanup_deadline = None
        timed_out = False
        truncated = False
        active_pipes = set(range(2))
        exit_code = w.DWORD(259)
        accounting = Accounting()
        while True:
            checked(get_exit(info.process, ctypes.byref(exit_code)))
            now = time.monotonic()
            if cleanup_deadline is None and (now >= deadline or wait_process(info.process, 0) == 0):
                timed_out = now >= deadline
                cleanup_deadline = now + cleanup
                checked(terminate_job(job, 124 if timed_out else 125))
            for stream in tuple(active_pipes):
                available = w.DWORD()
                if not peek_pipe(reads[stream], None, 0, None, ctypes.byref(available), None):
                    if ctypes.get_last_error() == 109:
                        active_pipes.remove(stream)
                        continue
                    checked(False)
                if available.value:
                    buffer = ctypes.create_string_buffer(min(65536, available.value))
                    count = w.DWORD()
                    checked(read_pipe(reads[stream], buffer, len(buffer), ctypes.byref(count), None))
                    truncated |= retain(buffers, stream, buffer.raw[:count.value])
            checked(query_job(job, 1, ctypes.byref(accounting), ctypes.sizeof(accounting), None))
            if accounting.active == 0 and not active_pipes:
                checked(get_exit(info.process, ctypes.byref(exit_code)))
                return (124 if timed_out else exit_code.value), True, truncated, time.monotonic() - start
            if cleanup_deadline is not None and time.monotonic() >= cleanup_deadline:
                return (124 if timed_out else 125), False, truncated, time.monotonic() - start
            time.sleep(0.01)
    finally:
        if info.process:
            if assigned:
                terminate_job(job, 125)
            else:
                terminate_process(info.process, 125)
            wait_process(info.process, 0)
        for item in writes + reads + [info.thread, info.process, job]:
            if item:
                close(item)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--timeout-ms", type=int, required=True)
    parser.add_argument("--cleanup-timeout-ms", type=int, required=True)
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    command = args.command[1:] if args.command[:1] == ["--"] else args.command
    if not command or not 0 < args.timeout_ms <= 2147483647 or not 0 < args.cleanup_timeout_ms <= 2147483647:
        parser.error("positive bounded deadlines and an executable are required")
    if os.environ.get("KANO_UNATTENDED", "").lower() not in ("0", "false", "no", "off"):
        os.environ["KANO_UNATTENDED"] = "1"
    os.environ["KANO_UNATTENDED_WATCHDOG_ACTIVE"] = "1"
    buffers = [bytearray(), bytearray()]
    try:
        runner = run_windows if os.name == "nt" else run_posix
        code, complete, truncated, elapsed = runner(command, args.timeout_ms / 1000,
                                                   args.cleanup_timeout_ms / 1000, buffers)
    except (OSError, RuntimeError) as error:
        print("[bootstrap-watchdog] launch/containment failure; cleanup-unverified: " + str(error), file=sys.stderr)
        return 125
    sys.stdout.buffer.write(buffers[0])
    sys.stderr.buffer.write(buffers[1])
    print("[bootstrap-watchdog] exit-code={} cleanup={} elapsed-ms={} truncated={}".format(
        code, "complete" if complete else "incomplete", int(elapsed * 1000), truncated), file=sys.stderr)
    return code if 0 <= code <= 255 else (128 - code if code < 0 else 1)


if __name__ == "__main__":
    sys.exit(main())
