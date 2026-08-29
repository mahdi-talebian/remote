# Remote Admin - E2E test report

Date     : 2026-08-29 14:10:50
Host     : e2b.local
Scenario : email-style tailnet (mmdtalebian.animid@gmail.com) + clean tailnet (mycorp.ts.net)
Real SSH : sshd on 127.0.0.1:22, user it_remote, password auth, OpenSSH client via sshpass
Mocked   : tailscale CLI control plane only

| # | Test | Result | Detail |
|---|---|---|---|
| 1 | parse: all 5 PowerShell scripts | PASS |  |
| 2 | deploy#1 exit code = 0 | PASS | exit=0 |
| 3 | deploy#1 prints [DEPLOY-STATUS] SUCCESS | PASS |  |
| 4 | deploy#1 marker = it_remote@127.0.0.1 (bare, email tailnet) | PASS | = Remote Admin deploy v3 (OS: Unix) = / Step 1/5: OpenSSH Server ... / OpenSSH server binary found: /usr/sbin/sshd / sshd service is active. / Step 2/5: remote account it_remote ... / local user 'it_remote' already exists (uid 1001). / password for it_remote updated. / Step 3/5: Tailscale ... / Joining tailnet as host 'mock-agent' ... / Tailscale is up (background service, auto-reconnects after reboot). / Step 4/5: firewall ... skipped (Windows-specific step; port 22 is governed by the OS firewall). / Step 5/5: building SSH address ... / ==================================================================== /   REMOTE SSH ADDRESS  ->   ssh it_remote@127.0.0.1 /   IP fallback        ->   ssh it_remote@127.0.0.1 /   User / Password    ->   it_remote / <the AdminPassword you entered> /   From YOUR machine (Tailscale logged in), run get-addresses.ps1 or open AdminConsole. / ==================================================================== / SSH-ADDRESS: it_remote@127.0.0.1 / IP-FALLBACK: it_remote@127.0.0.1 / Deployment complete. / [DEPLOY-STATUS] SUCCESS /  |
| 5 | deploy#1 no CLIXML noise | PASS |  |
| 6 | deploy#1 wrote last-address.txt | PASS |  |
| 7 | deploy#1 last-address.txt content | PASS | got: ssh it_remote@127.0.0.1 |
| 8 | deploy#1 ssh-address.txt has SSH-ADDRESS + IP fallback | PASS |  |
| 9 | agent sees controller in tailnet | PASS |  |
| 10 | admin sees agent in tailnet | PASS |  |
| 11 | admin sees agent ONLINE | PASS |  |
| 12 | get-addresses shows agent as ONLINE | PASS |  |
| 13 | get-addresses saves ssh-addresses.txt | PASS |  |
| 14 | REAL ssh login succeeds (password auth, address from scripts) | PASS | Warning: Permanently added '127.0.0.1' (ED25519) to the list of known hosts. e2b.local SSH-CONNECTED  |
| 15 | deploy#2 exit code = 0 | PASS | exit=0 |
| 16 | deploy#2 address = it_remote@agent2.mycorp.ts.net (DNS, clean tailnet) | PASS |  |
| 17 | deploy#2 last-address.txt = DNS form | PASS | got: ssh it_remote@agent2.mycorp.ts.net |
| 18 | deploy#bad-key exit code = 1 | PASS | exit=1 |
| 19 | deploy#bad-key marks FAILED | PASS |  |
| 20 | deploy#bad-key warns about tskey-auth | PASS |  |
| 21 | wizard: Get-NewLines / Get-AuthoritativeAddress / Parse-Address extractable | PASS |  |
| 22 | Parse-Address: current marker (bare) -> full | PASS |  |
| 23 | Parse-Address: old marker (ssh prefix) -> full | PASS |  |
| 24 | Parse-Address: last-address.txt line -> full | PASS |  |
| 25 | Parse-Address: bare address -> full | PASS |  |
| 26 | Parse-Address: partial marker "SSH-ADDRESS: ssh" REJECTED | PASS |  |
| 27 | Parse-Address: random log line -> empty | PASS |  |
| 28 | Parse-Address: Tailnet line -> empty | PASS |  |
| 29 | wizard streaming sim: full address recovered from deploy#1 log | PASS | got: ssh it_remote@127.0.0.1 |
| 30 | wizard Get-NewLines: single-line file returns the LINE (bug fixed) | PASS | count=1, first='SSH-ADDRESS: ssh it_remote@127.0.0.1' |
| 31 | wizard Get-NewLines: incremental read works | PASS |  |
| 32 | wizard address recovery from last-address.txt | PASS |  |
| 33 | wizard address recovery from ssh-address.txt | PASS |  |
| 34 | console: Build-Address extractable | PASS |  |
| 35 | console Build-Address: email tailnet -> IP form | PASS |  |
| 36 | console Build-Address: clean tailnet -> DNS form | PASS |  |
| 37 | console Build-Address: full DNS row stays as-is | PASS |  |
| 38 | ctor: OLD New-Object(array) pattern fails (the shipped bug) | PASS | got object, but should be null; err=Cannot find an overload for "FakeLVI" and the argument count: "4". |
| 39 | ctor: NEW ::new(array) pattern binds string[] ctor | PASS | subitems=4 |
| 40 | ctor: Tag/ToolTipText settable on ::new item | PASS |  |
| 41 | ctor: ::new(text) + SubItems.AddRange fallback works | PASS |  |
| 42 | console: New-ListViewItem extractable (defensive creation) | PASS |  |
