#!/usr/bin/env python3
"""Run the optional OpenSSH integration tests using only temporary loopback services."""

from contextlib import ExitStack
from getpass import getuser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from tempfile import TemporaryDirectory
import json
import os
import socket
import subprocess
import threading
import time


class FixtureHandler(BaseHTTPRequestHandler):
    """Return a known body so each forwarding rule makes a genuine application request."""

    def do_GET(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"portlane-fixture")

    def log_message(self, *_args):
        return


def stop(process):
    """Reap only children started by this script, even after a test failure."""
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=4)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()


def wait_for_port(port, process):
    """Wait for the expected loopback listener while checking the child still exists."""
    for _attempt in range(100):
        if process.poll() is not None:
            raise RuntimeError(f"Fixture process exited with status {process.returncode}")
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return
        except OSError:
            time.sleep(0.05)
    raise RuntimeError(f"Loopback port {port} did not become ready")


def allocate_ports():
    """Reserve distinct ephemeral port numbers before starting the fixture processes."""
    with ExitStack() as stack:
        sockets = [stack.enter_context(socket.socket()) for _index in range(6)]
        for listener in sockets:
            listener.bind(("127.0.0.1", 0))
        return [listener.getsockname()[1] for listener in sockets]


def run_fixture(project):
    """Isolate keys, host trust and listeners from the user's SSH configuration."""
    with ExitStack() as stack:
        directory = Path(stack.enter_context(TemporaryDirectory(prefix="portlane-test-", dir="/tmp")))
        ssh_port, local_port, remote_port, socks_port, first_external, second_external = allocate_ports()
        http = ThreadingHTTPServer(("127.0.0.1", 0), FixtureHandler)
        threading.Thread(target=http.serve_forever, daemon=True).start()
        stack.callback(http.server_close)
        stack.callback(http.shutdown)

        host_key = directory / "host_ed25519"
        client_key = directory / "client_ed25519"
        for key in (host_key, client_key):
            subprocess.run(["/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(key)], check=True)
        authorized = directory / "authorized_keys"
        authorized.write_text(client_key.with_suffix(".pub").read_text())
        known_hosts = directory / "known_hosts"
        known_hosts.write_text(f"[127.0.0.1]:{ssh_port} " + host_key.with_suffix(".pub").read_text())
        configuration = directory / "sshd_config"
        configuration.write_text("\n".join([
            f"Port {ssh_port}", "ListenAddress 127.0.0.1", f"HostKey {host_key}",
            f"AuthorizedKeysFile {authorized}", f"PidFile {directory / 'sshd.pid'}",
            "UsePAM no", "StrictModes no", "PasswordAuthentication no", "KbdInteractiveAuthentication no",
            "AllowTcpForwarding yes", "GatewayPorts clientspecified",
        ]) + "\n")
        sshd = subprocess.Popen(["/usr/sbin/sshd", "-D", "-e", "-f", str(configuration)])
        stack.callback(stop, sshd)
        wait_for_port(ssh_port, sshd)

        external = subprocess.Popen([
            "/usr/bin/ssh", "-N", "-F", "/dev/null", "-p", str(ssh_port),
            "-o", "BatchMode=yes", "-o", "ExitOnForwardFailure=yes", "-o", "StrictHostKeyChecking=yes",
            "-o", f"UserKnownHostsFile={known_hosts}", "-o", "IdentitiesOnly=yes", "-i", str(client_key),
            "-L", f"127.0.0.1:{first_external}:127.0.0.1:{http.server_port}",
            "-L", f"127.0.0.1:{second_external}:127.0.0.1:{http.server_port}",
            "--", f"{getuser()}@127.0.0.1",
        ], stdin=subprocess.DEVNULL)
        stack.callback(stop, external)
        wait_for_port(first_external, external)
        (directory / "manifest.json").write_text(json.dumps({
            "sshPort": ssh_port, "webPort": http.server_port, "localPort": local_port,
            "remotePort": remote_port, "socksPort": socks_port, "externalPID": external.pid,
            "externalPorts": [first_external, second_external],
        }))
        bin_path = subprocess.check_output(["swift", "build", "--show-bin-path"], cwd=project, text=True).strip()
        environment = dict(os.environ, PORTLANE_SSH_FIXTURE=str(directory),
                           PORTLANE_TEST_HELPER=str(Path(bin_path) / "Lane"))
        return subprocess.run(["swift", "test"], cwd=project, env=environment, timeout=300).returncode


if __name__ == "__main__":
    raise SystemExit(run_fixture(Path(__file__).resolve().parent.parent))
