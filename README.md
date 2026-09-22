# Windows post-update health check

A small Ansible playbook that collects information from each Windows server
after updates and writes one CSV report.

It is **informative only**: no thresholds, no pass/fail. It reports what it
finds and leaves the judgement to you.

Nothing is changed on the servers.

## What it collects

| Item | Where it comes from |
|---|---|
| Last reboot time | fact `ansible_lastboot` |
| Uptime | fact `ansible_uptime_seconds` |
| OS name | fact `ansible_distribution` |
| Pending restart (+ reasons) | PowerShell, registry |
| Automatic services not running | PowerShell, `Win32_Service` |
| Named services you watch | PowerShell, `Get-Service` |
| `C:` size, free space, free % | PowerShell, `Win32_LogicalDisk` |
| URL checks (+ content) | PowerShell, `Invoke-WebRequest`, from the server |

There is no Windows fact for disk space, which is why the drive goes through
PowerShell like the rest.

## Files

```
windows_health_check.yml     the playbook
files/checks.ps1             the PowerShell run on each server
templates/report.csv.j2      the CSV layout
group_vars/windows.yml       what to watch: services, URLs, drive
```

`files/checks.ps1` is a plain PowerShell script, not a template. The playbook
runs it with `ansible.windows.win_powershell`, which hands your settings to
its `param()` block as real parameters and reads the result back from
`$Ansible.Result`. Nothing is pasted into the script text, so no value ever
needs escaping, and the file stays a normal `.ps1` you can open, edit and run
in a PowerShell console on its own.

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

- the `ansible.windows` collection (1.5.0 or newer, for `win_powershell`)
- SSH or WinRM already working against the servers (this playbook does not
  configure the connection — that stays in your inventory)
