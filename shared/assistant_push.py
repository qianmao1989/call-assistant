"""
Assistant Push - Send push messages to CC via named pipe.
Pipe: \\.\pipe\openclaw-cc-push
Protocol: JSON {"type":"push","from":"assistant","text":"...","ts":epoch}

Usage:
    from assistant_push import push_to_cc, is_cc_alive, push_message
    push_to_cc("CC, please run the build")
    # or
    push_message({"type":"push","from":"assistant","text":"hello","ts":time.time()})
"""

import json
import time
import os
import sys

PIPE_PATH = r'\\.\pipe\openclaw-cc-push'
ALIVE_FILE = r'D:\CherryAI_Workspace\shared\cc_alive'


def is_pipe_available():
    """Check if the named pipe exists (CC server is listening)."""
    return os.path.exists(PIPE_PATH)


def is_cc_alive():
    """Check if CC's alive heartbeat file exists."""
    return os.path.exists(ALIVE_FILE)


def get_cc_info():
    """Read CC's alive file metadata. Returns dict or None."""
    try:
        if not os.path.exists(ALIVE_FILE):
            return None
        with open(ALIVE_FILE, 'r') as f:
            return json.loads(f.read())
    except Exception:
        return None


def push_message(msg):
    """
    Send a message dict to CC via named pipe.
    msg should be a dict, will be JSON-serialized.
    Returns True on success, False on failure.
    """
    if not isinstance(msg, dict):
        raise TypeError("msg must be a dict")

    payload = json.dumps(msg, ensure_ascii=False) + '\n'

    try:
        # Use cmd.exe to write to the named pipe via PowerShell
        # On Windows, we can write to named pipes using Python's open() or ctypes
        # The simplest cross-method approach: use PowerShell's Out-File
        import subprocess

        # Encode the payload for PowerShell
        encoded = payload.encode('utf-8')

        # Method: use \\.\pipe\... directly - Python can open named pipes on Windows
        # but the syntax varies. Use subprocess with PowerShell as fallback.
        result = subprocess.run(
            [
                'powershell', '-NoProfile', '-Command',
                f'[System.IO.File]::WriteAllBytes("{PIPE_PATH}", [System.Text.Encoding]::UTF8.GetBytes(@\'\n{payload}\'@))'
            ],
            capture_output=True, timeout=5, text=True
        )
        if result.returncode == 0:
            return True

        # Fallback: try direct file write (works on some Windows versions)
        try:
            with open(PIPE_PATH, 'w', encoding='utf-8') as f:
                f.write(payload)
                f.flush()
            return True
        except Exception:
            pass

        # Fallback 2: use ctypes to write via CreateFile
        try:
            import ctypes
            from ctypes import wintypes

            GENERIC_WRITE = 0x40000000
            OPEN_EXISTING = 3
            FILE_ATTRIBUTE_NORMAL = 0x80

            kernel32 = ctypes.WinDLL('kernel32', use_last_error=True)
            kernel32.CreateFileW.argtypes = [
                wintypes.LPCWSTR, wintypes.DWORD, wintypes.DWORD,
                wintypes.LPVOID, wintypes.DWORD, wintypes.DWORD,
                wintypes.HANDLE
            ]
            kernel32.CreateFileW.restype = wintypes.HANDLE
            kernel32.WriteFile.argtypes = [
                wintypes.HANDLE, wintypes.LPVOID, wintypes.DWORD,
                ctypes.POINTER(wintypes.DWORD), wintypes.LPVOID
            ]
            kernel32.WriteFile.restype = wintypes.BOOL
            kernel32.CloseHandle.argtypes = [wintypes.HANDLE]
            kernel32.CloseHandle.restype = wintypes.BOOL

            INVALID_HANDLE_VALUE = wintypes.HANDLE(-1).value

            handle = kernel32.CreateFileW(
                PIPE_PATH,
                GENERIC_WRITE,
                0, None,
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                None
            )

            if handle == INVALID_HANDLE_VALUE:
                print(f"[push] CreateFile failed: {ctypes.get_last_error()}", flush=True)
                return False

            data = payload.encode('utf-8')
            bytes_written = wintypes.DWORD(0)
            ok = kernel32.WriteFile(
                handle,
                data,
                len(data),
                ctypes.byref(bytes_written),
                None
            )
            kernel32.CloseHandle(handle)

            if ok and bytes_written.value == len(data):
                return True
            else:
                print(f"[push] WriteFile incomplete: {bytes_written.value}/{len(data)}", flush=True)
                return False

        except Exception as e:
            print(f"[push] ctypes write failed: {e}", flush=True)
            return False

    except subprocess.TimeoutExpired:
        print("[push] PowerShell write timed out", flush=True)
        return False
    except Exception as e:
        print(f"[push] error: {e}", flush=True)
        return False


def push_to_cc(text):
    """
    Convenience: send a text message to CC.
    Constructs the standard push protocol message.
    """
    msg = {
        "type": "push",
        "from": "assistant",
        "text": text,
        "ts": time.time()
    }
    ok = push_message(msg)
    if ok:
        print(f"[push] sent to CC: {text[:100]}", flush=True)
    else:
        print(f"[push] FAILED to send: {text[:100]}", flush=True)
    return ok


def push_to_cc_sync(text, timeout=30, poll_interval=0.5):
    """
    Push to CC and wait for a response message.
    This is a blocking call - use for request/response patterns.
    NOTE: CC responds via Gateway API, not the pipe. This function just sends.
    For response, you'd need to check the pipe from CC's side.
    """
    return push_to_cc(text)


# CLI interface
if __name__ == '__main__':
    if len(sys.argv) < 2:
        print("Usage: python assistant_push.py <message>")
        print("       python assistant_push.py --check")
        print("       python assistant_push.py --alive")
        sys.exit(1)

    if sys.argv[1] == '--check':
        available = is_pipe_available()
        print(f"Pipe available: {available}")
        if available:
            info = get_cc_info()
            if info:
                print(f"CC info: {json.dumps(info, indent=2)}")
        sys.exit(0 if available else 1)

    if sys.argv[1] == '--alive':
        alive = is_cc_alive()
        print(f"CC alive: {alive}")
        if alive:
            info = get_cc_info()
            print(f"CC info: {json.dumps(info, indent=2)}")
        sys.exit(0 if alive else 1)

    text = ' '.join(sys.argv[1:])
    ok = push_to_cc(text)
    sys.exit(0 if ok else 1)
