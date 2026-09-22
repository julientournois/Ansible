# Windows post-update health check

A small Ansible playbook that collects information from each Windows server
after updates and writes one CSV report.

It is **informative only**: no thresholds, no pass/fail. It reports what it
finds and leaves the judgement to you.

Nothing is changed on the servers.

## What it collects

One task per item, so the playbook output tells you exactly which check ran
and which one had a problem.

| Item | Task |
|---|---|
| Uptime, OS name | `gather_facts` (`ansible_uptime_seconds`, `ansible_distribution`) |
| Last reboot time, pending restart (+ reasons) | `win_reboot_info` |
| Automatic services not running | `win_powershell`, `Win32_Service` |
| Named services you watch | `win_powershell`, `Get-Service` |
| `C:` size, free space, free % | `win_powershell`, `Win32_LogicalDisk` |
| URL checks (+ content) | `win_uri`, called from the server |

There is no Windows fact for disk space, which is why the drive goes through
`win_powershell`.

Each gathering task carries `failed_when: false`. A check that fails costs you
that one column, not the whole server: the task shows up red in the output and
the column comes out **empty** in the CSV. Empty means "not checked" — the
report never fills a blank with a reassuring `no` or `0`.

## Files

```
windows_health_check.yml     the playbook, everything is in here
templates/report.csv.j2      the CSV layout
group_vars/windows.yml       what to watch: services, URLs, drive
```

The PowerShell is inline in the tasks, and values reach it through
`parameters:`, bound to a `param()` block. Nothing is pasted into the script
text, so no value ever needs escaping.

Your own `ansible.cfg` and your inventory `.ini` stay where they are. The
playbook only expects a group of Windows servers.

## Running it

```bash
ansible-galaxy collection install -r requirements.yml

ansible-playbook -i /path/to/your/inventory.ini windows_health_check.yml
```

The report lands in `reports/YYYY-MM/health_YYYYMMDD-HHMMSS.csv`, next to the
playbook.

Run it **from this directory**. `group_vars/windows.yml` is picked up because
it sits next to the playbook; if you run the playbook from somewhere else,
Ansible will not find it and the run stops on `check_drive is undefined`. The
other option is to put `group_vars/` next to your inventory file instead —
either location works, just not a copy in both.

## Settings

Everything you are likely to change is in `group_vars/windows.yml`:

```yaml
check_drive: "C:"

check_services:            # checked by name, whatever their start mode
  - Winmgmt
  - W3SVC

check_urls:                # called from the server itself
  - name: intranet
    url: "http://{{ inventory_hostname | lower }}/"
    expect_content: "Welcome"   # optional
```

The file is named after the inventory group. If your group is not called
`windows`, rename it (`group_vars/<your group>.yml`) and change the `hosts:`
line at the top of the playbook to match.

`check_url_ignore_cert_errors: true` is on by default, because internal sites
commonly use self-signed certificates. Set it to `false` if you want
certificate errors to show up as failed URL checks.

## The CSV

One row per server, 14 columns: `server`, `checked_at`, `os`, `last_boot`,
`uptime_days`, `pending_restart`, `pending_reasons`,
`auto_services_stopped_count`, `auto_services_stopped`, `watched_services`,
`disk_total_gb`, `disk_free_gb`, `disk_free_pct`, `urls`.

Lists are joined with ` | ` inside one cell, for example
`Winmgmt=Running | W3SVC=Stopped`.

The delimiter is `;`, which opens cleanly in a French Excel. Change
`report_delimiter` in the second play for `,`.

A server that cannot be reached still gets a row, with `not reachable` in the
`os` column and the rest empty — so it cannot silently disappear from the
report.

## Requirements

- the `ansible.windows` collection, **3.8.0 or newer**
- SSH or WinRM already working against the servers (this playbook does not
  configure the connection — that stays in your inventory)

Check what you have:

```bash
ansible-galaxy collection list ansible.windows
```

3.8.0 is required only for `win_reboot_info`, which is recent. If you are
stuck on an older collection, replace that one task with:

```yaml
    - name: Check whether a restart is pending
      ansible.windows.win_powershell:
        script: |
          $Ansible.Changed = $false
          $reasons = @()
          if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'CBS' }
          if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'WindowsUpdate' }
          $Ansible.Result = @{ required = $reasons.Count -gt 0; reasons = $reasons }
      register: reboot
      failed_when: false
```

and read `reboot.result.required` / `reboot.result.reasons` in the assembling
task instead, plus `ansible_lastboot` from the facts for the boot time. Then
`win_powershell` alone is enough, and that goes back to 1.5.0.
