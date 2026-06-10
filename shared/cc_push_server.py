"""
CC Push Server - Named pipe daemon for receiving push messages from Assistant.
Pipe: \\.\pipe\openclaw-cc-push
Protocol: JSON {"type":"push","from":"assistant","text":"...","ts":epoch}

Usage:
    from cc_push_server import start_push_server, get_pending_messages
    start_push_server()
    # ... later ...
    messages = get_pending_messages()  # returns list of dicts
"""

import json
import threading
import time
import os
import sys
from collections import deque

# Force UTF-8 output to handle emoji / CJK
sys.stdout.reconfigure(encoding='utf-8', errors='replace')

# Windows named pipe constants
PIPE_ACCESS_DUPLEX = 0x00000003
PIPE_TYPE_BYTE = 0x00000000
PIPE_READMODE_BYTE = 0x00000000
PIPE_WAIT = 0x00000000
INVALID_HANDLE_VALUE = -1
BUFFER_SIZE = 65536

PIPE_NAME = r'\\.\pipe\openclaw-cc-push'
ALIVE_FILE = r'D:\CherryAI_Workspace\shared\cc_alive'
INBOX_FILE = r'D:\CherryAI_Workspace\shared\cc_pipe_inbox.json'

_pending = deque()
_lock = threading.Lock()
_server_thread = None
_running = False

# Try to load ctypes for Windows
try:
    import ctypes
    from ctypes import wintypes

    kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)

    # Define Windows API functions
    kernel32.CreateNamedPipeW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
        wintypes.DWORD, wintypes.DWORD, wintypes.DWORD,
        wintypes.DWORD, wintypes.LPVOID
    ]
    kernel32.CreateNamedPipeW.restype = wintypes.HANDLE

    kernel32.ConnectNamedPipe.argtypes = [wintypes.HANDLE, wintypes.LPVOID]
    kernel32.ConnectNamedPipe.restype = wintypes.BOOL

    kernel32.ReadFile.argtypes = [
        wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
        ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID
    ]
    kernel32.ReadFile.restype = wintypes.BOOL

    kernel32.DisconnectNamedPipe.argtypes = [wintypes.HANDLE]
    kernel32.DisconnectNamedPipe.restype = wintypes.BOOL

    kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
    kernel32.CloseHandle.restype = wintypes.BOOL

    kernel32.FlushFileBuffers.argtypes = [wintypes.HANDLE]
    kernel32.FlushFileBuffers.restype = wintypes.BOOL

    HAS_CTYPES = True
except Exception:
    HAS_CTYPES = False


def _write_alive_file():
    """Create the cc_alive heartbeat file."""
    try:
        os.makedirs(os.path.dirname(ALIVE_FILE), exist_ok=True)
        with open(ALIVE_FILE, 'w') as f:
            f.write(json.dumps({
                "pid": os.getpid(),
                "started": time.time(),
                "started_iso": time.strftime('%Y-%m-%dT%H:%M:%S%z'),
                "pipe": PIPE_NAME
            }))
        print(f"[cc_push] alive file written: {ALIVE_FILE}", flush=True)
    except Exception as e:
        print(f"[cc_push] failed to write alive file: {e}", flush=True)


def _remove_alive_file():
    """Remove the cc_alive heartbeat file."""
    try:
        if os.path.exists(ALIVE_FILE):
            os.remove(ALIVE_FILE)
            print(f"[cc_push] alive file removed: {ALIVE_FILE}", flush=True)
    except Exception as e:
        print(f"[cc_push] failed to remove alive file: {e}", flush=True)


def _save_to_inbox(msg):
    """Append received message to inbox JSON file with proper UTF-8."""
    try:
        existing = []
        if os.path.exists(INBOX_FILE):
            with open(INBOX_FILE, 'r', encoding='utf-8') as f:
                existing = json.loads(f.read())
        existing.append(msg)
        with open(INBOX_FILE, 'w', encoding='utf-8') as f:
            json.dump(existing, f, ensure_ascii=False, indent=2)
    except Exception as e:
        print(f"[cc_push] inbox write failed: {e}", flush=True)


def _build_null_dacl_security_attributes():
    """
    Build a SECURITY_ATTRIBUTES struct with a NULL DACL (allows everyone access).
    This fixes Access Denied (error 5) when a client process tries to connect.
    """
    # SECURITY_DESCRIPTOR with NULL DACL
    # ConvertStringSecurityDescriptorToSecurityDescriptorW with "D:(A;;GA;;;WD)" (SDDL)
    # "D:(A;;GA;;;WD)" = DACL: Allow GenericAll to Everyone
    import ctypes
    from ctypes import wintypes

    advapi32 = ctypes.WinDLL('advapi32', use_last_error=True)
    advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW.restype = wintypes.BOOL
    advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW.argtypes = [
        wintypes.LPCWSTR, wintypes.DWORD,
        ctypes.POINTER(ctypes.c_void_p), ctypes.POINTER(wintypes.DWORD)
    ]

    sd = ctypes.c_void_p()
    sd_size = wintypes.DWORD(0)
    # SDDL: D:(A;;GA;;;WD) means DACL with Allow GenericAll to Everyone
    ok = advapi32.ConvertStringSecurityDescriptorToSecurityDescriptorW(
        "D:(A;;GA;;;WD)",  # SDDL string
        1,  # SDDL_REVISION_1
        ctypes.byref(sd),
        ctypes.byref(sd_size)
    )
    if not ok:
        print(f"[cc_push] WARNING: ConvertStringSecurityDescriptor failed, error={ctypes.get_last_error()}, falling back to no security", flush=True)
        return None

    # Build SECURITY_ATTRIBUTES
    class SECURITY_ATTRIBUTES(ctypes.Structure):
        _fields_ = [
            ("nLength", wintypes.DWORD),
            ("lpSecurityDescriptor", ctypes.c_void_p),
            ("bInheritHandle", wintypes.BOOL),
        ]

    sa = SECURITY_ATTRIBUTES()
    sa.nLength = ctypes.sizeof(SECURITY_ATTRIBUTES)
    sa.lpSecurityDescriptor = sd
    sa.bInheritHandle = False
    # Keep a reference so sd isn't garbage-collected
    sa._sd_ref = sd
    return ctypes.byref(sa)


def _pipe_server_loop():
    """Main loop: create pipe instance, wait for connection, read data, repeat."""
    if not HAS_CTYPES:
        print("[cc_push] ERROR: ctypes not available, cannot create named pipe on this platform", flush=True)
        return

    print(f"[cc_push] starting pipe server on {PIPE_NAME}", flush=True)
    _write_alive_file()

    # Build a security descriptor with NULL DACL so any client on the
    # same machine can open the pipe (fixes Access Denied error 5).
    _sec_attr = _build_null_dacl_security_attributes()

    while _running:
        pipe_handle = kernel32.CreateNamedPipeW(
            PIPE_NAME,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            255,  # max instances
            0,  # out buffer
            BUFFER_SIZE,  # in buffer
            0,  # default timeout
            _sec_attr  # security: NULL DACL
        )

        if pipe_handle == INVALID_HANDLE_VALUE:
            err = ctypes.get_last_error()
            print(f"[cc_push] CreateNamedPipe failed, error={err}", flush=True)
            time.sleep(2)
            continue

        # Wait for client to connect
        print("[cc_push] waiting for connection...", flush=True)
        connected = kernel32.ConnectNamedPipe(pipe_handle, None)
        if not connected:
            err = ctypes.get_last_error()
            # ERROR_PIPE_CONNECTED (535) means client connected before ConnectNamedPipe
            if err != 535:
                kernel32.CloseHandle(pipe_handle)
                print(f"[cc_push] ConnectNamedPipe failed, error={err}", flush=True)
                time.sleep(1)
                continue

        print("[cc_push] client connected, reading...", flush=True)

        # Read data
        chunks = []
        bytes_read = wintypes.DWORD(0)
        buf = ctypes.create_string_buffer(BUFFER_SIZE)

        while True:
            ok = kernel32.ReadFile(
                pipe_handle,
                buf,
                BUFFER_SIZE - 1,
                ctypes.byref(bytes_read),
                None
            )
            if not ok or bytes_read.value == 0:
                break
            chunks.append(buf.raw[:bytes_read.value])

        kernel32.DisconnectNamedPipe(pipe_handle)
        kernel32.CloseHandle(pipe_handle)

        if not chunks:
            continue

        raw = b''.join(chunks).decode('utf-8', errors='replace').strip()
        if not raw:
            continue

        # Parse JSON (may be newline-delimited multiple messages)
        for line in raw.split('\n'):
            line = line.strip()
            if not line:
                continue
            try:
                msg = json.loads(line)
                with _lock:
                    _pending.append(msg)
                print(f"[cc_push] received: {msg}", flush=True)
                _save_to_inbox(msg)
            except json.JSONDecodeError:
                print(f"[cc_push] invalid JSON: {line[:200]}", flush=True)

    _remove_alive_file()
    print("[cc_push] server stopped", flush=True)


def start_push_server():
    """Start the push server as a daemon thread. Safe to call multiple times."""
    global _server_thread, _running
    if _running:
        print("[cc_push] already running", flush=True)
        return
    _running = True
    _server_thread = threading.Thread(target=_pipe_server_loop, daemon=True, name="cc-push-server")
    _server_thread.start()
    print("[cc_push] server thread started", flush=True)


def stop_push_server():
    """Signal the server to stop. Does not block."""
    global _running
    _running = False
    print("[cc_push] stop requested", flush=True)


def get_pending_messages():
    """
    Get and clear all pending push messages.
    Returns list of dicts: [{"type":"push","from":"assistant","text":"...","ts":...}, ...]
    """
    with _lock:
        msgs = list(_pending)
        _pending.clear()
    return msgs


def peek_messages():
    """Peek at pending messages without consuming them."""
    with _lock:
        return list(_pending)


def has_messages():
    """Check if there are pending messages."""
    with _lock:
        return len(_pending) > 0


# Auto-start if run directly
if __name__ == '__main__':
    print("[cc_push] starting as standalone daemon...", flush=True)
    start_push_server()
    try:
        while True:
            time.sleep(1)
            if has_messages():
                msgs = get_pending_messages()
                for m in msgs:
                    print(f"[cc_push] MSG: {m}", flush=True)
                    _save_to_inbox(m)
    except KeyboardInterrupt:
        print("\n[cc_push] shutting down...", flush=True)
        stop_push_server()
        time.sleep(1)
