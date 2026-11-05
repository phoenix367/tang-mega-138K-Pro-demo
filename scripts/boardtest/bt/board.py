"""The board over ssh, the way the harness uses it.

- One OpenSSH ControlMaster connection for the whole run: the board's dropbear has no
  key installed (ae350 / ae350, doc/03-boot.md), so the password is typed once, and
  every later command skips the A25's slow key exchange.
- run(): a command as the user.  root(): a shell script as root -- written locally,
  copied to /tmp/bt/ and run with `doas sh FILE` on a tty (doas wants one).  Never
  `doas sh -c '...'` through ssh: the quotes do not survive the two shells.
- put() / get(): scp -O (dropbear's scp).
"""
import os, re, socket, subprocess, tempfile, time

import pexpect

PROMPT = re.compile(r"[Pp]assword[^\r\n]*:\s*$")


class BoardError(Exception):
    pass


class Board:
    def __init__(self, host, user="ae350", password="ae350"):
        self.host, self.user, self.password = host, user, password
        self.tmp = tempfile.mkdtemp(prefix="bt-")
        self.ctl = os.path.join(self.tmp, "ssh")
        self.opts = ["-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null",
                     "-o", "PreferredAuthentications=password,keyboard-interactive",
                     "-o", "PubkeyAuthentication=no", "-o", "LogLevel=ERROR", "-o", "ConnectTimeout=10",
                     "-o", "ControlMaster=auto", "-o", "ControlPath=" + self.ctl, "-o", "ControlPersist=600",
                     "-o", "ServerAliveInterval=10"]
        self.nscript = 0
        self.btdir = False                      # /tmp/bt made on the board

    # -- plumbing -------------------------------------------------------------
    def _go(self, argv, timeout):
        """Run argv locally on a pty, answer password prompts (ssh's and doas's),
        return (exit status, output without CRs)."""
        c = pexpect.spawn(argv[0], argv[1:], encoding="utf-8", codec_errors="replace", timeout=timeout)
        out, answered = [], 0
        deadline = time.time() + timeout
        while True:
            try:
                i = c.expect([PROMPT, pexpect.EOF], timeout=max(1, deadline - time.time()))
            except pexpect.TIMEOUT:
                out.append(c.before or "")
                c.close(force=True)
                raise BoardError("timeout after %d s: %s" % (timeout, " ".join(argv[-1:])[:120]))
            before = c.before or ""
            if i == 0:                              # a prompt: drop its line ("doas (u@h) password:")
                before = before.rsplit("\n", 1)[0] + "\n" if "\n" in before else ""
            out.append(before)
            if i == 1:
                break
            if answered >= 3:
                c.close(force=True)
                raise BoardError("password refused")
            c.sendline(self.password)
            answered += 1
        c.close()
        rc = c.exitstatus if c.exitstatus is not None else 128 + (c.signalstatus or 0)
        return rc, "".join(out).replace("\r", "")

    def reachable(self, port=22, timeout=3):
        try:
            socket.create_connection((self.host, port), timeout=timeout).close()
            return True
        except OSError:
            return False

    # -- commands -------------------------------------------------------------
    def run(self, cmd, timeout=60):
        """A shell command as the user (no tty); (rc, output)."""
        return self._go(["ssh", *self.opts, "%s@%s" % (self.user, self.host), cmd], timeout)

    def root(self, script, timeout=60):
        """A shell script as root through doas; (rc, output)."""
        self.nscript += 1
        local = os.path.join(self.tmp, "s%d.sh" % self.nscript)
        with open(local, "w") as f:
            f.write("#!/bin/sh\n" + script)
        remote = "/tmp/bt/s%d.sh" % self.nscript
        if not self.btdir:
            self.run("mkdir -p /tmp/bt")
            self.btdir = True
        self.put(local, remote)
        rc, out = self._go(["ssh", "-tt", *self.opts, "%s@%s" % (self.user, self.host), "doas sh " + remote], timeout)
        return rc, out.lstrip("\n")

    def put(self, local, remote, timeout=600):
        rc, out = self._go(["scp", *self.opts, "-O", local, "%s@%s:%s" % (self.user, self.host, remote)], timeout)
        if rc:
            raise BoardError("scp to %s failed: %s" % (remote, out.strip()[-200:]))

    def get(self, remote, local, timeout=600):
        rc, out = self._go(["scp", *self.opts, "-O", "%s@%s:%s" % (self.user, self.host, remote), local], timeout)
        if rc:
            raise BoardError("scp from %s failed: %s" % (remote, out.strip()[-200:]))

    def login_term(self, term, timeout=30):
        """An interactive login shell from a client whose TERM is `term`: the TERM the
        shell ends up with (after /etc/profile)."""
        env = dict(os.environ, TERM=term)
        c = pexpect.spawn("ssh", ["-tt", *self.opts, "%s@%s" % (self.user, self.host)], env=env,
                          encoding="utf-8", codec_errors="replace", timeout=timeout)
        try:
            while c.expect([PROMPT, r"\$ "]) == 0:
                c.sendline(self.password)
            c.sendline('echo "TERM=[$TERM]"; exit')
            c.expect(r"TERM=\[([^\]$]*)\]")
            return c.match.group(1)
        finally:
            c.close(force=True)

    def close(self):
        subprocess.run(["ssh", *self.opts, "-O", "exit", "%s@%s" % (self.user, self.host)],
                       capture_output=True, timeout=10)
