# Database & Workload Collectors

## Files

- `Get-SqlServerInventory.ps1` - remote SQL Server discovery, instance topology, and metadata collector.
- `get_turbonomic_metrics.py` - Turbonomic VM metrics, capacity utilization, and action recommendations collector.
- `../config/config.json` - Unified project input configuration file.
- `../output/` - generated reports are written here.

## Input

VM targets, connection addresses, and credentials are centrally configured in `../config/config.json`:

```json
{
  "targets": {
    "windows": [
      {
        "vm_name": "SQLVM01",
        "nameOrAddress": "10.0.1.10",
        "username": "turbowmi",
        "password": "Password123!"
      }
    ]
  }
}
```

`nameOrAddress` can be a hostname or IP address.

## Run

From a central Windows management VM:

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\Get-SqlServerInventory.ps1 `
    -InputFile ..\config\config.json `
    -OutputDirectory ..\output
```

The script prompts for a credential.

If the current Windows identity already has the required permissions:

```powershell
.\Get-SqlServerInventory.ps1 `
    -InputFile ..\config\config.json `
    -UseCurrentCredential `
    -OutputDirectory ..\output
```

## What it collects

### VM
- hostname
- domain/workgroup
- manufacturer/model
- OS/version/build
- CPU
- RAM
- BIOS/serial/UUID
- disks and free space
- network adapters/IP/DNS/gateway

### SQL Server WMI/CIM
- SQL WMI namespaces
- SQL Server services
- SQL Agent
- SQL Browser
- default/named instances
- service state
- startup mode
- service account
- instance ID
- SQL installation paths
- registry version/edition/patch information
- TCP configuration

### SQL Server engine (no SQL login or password)
Collected from the SQL Server WMI provider (`SqlServiceAdvancedProperty`) and the registry:
- ServerName / MachineName / InstanceName
- Edition and EditionID
- ProductVersion and ProductLevel (RTM / SPn)
- clustering (`CLUSTERED`, virtual server name)
- HADR enabled (registry `HADR_Enabled`)
- authentication mode (registry `LoginMode`)
- collation
- cluster nodes, when the Failover Cluster WMI provider is present (best effort)

### Databases (no SQL login or password)
Collected from the `SQLServer:Databases` performance-counter WMI class and the instance's data/log directories:
- database name
- files, physical paths and on-disk size
- log used space (`LogFilesUsedSizeKB`)

### Not collected (needs a SQL connection)
These columns stay empty in the JSON, CSV and reports:
- licence type and number of licences
- product update level / reference, resource version, engine edition
- Always On AG replicas and role, log shipping, database mirroring
- per-database state, user access, recovery model, compatibility level, read-only, auto-close/shrink, Service Broker, trustworthy, DB chaining, encryption, Query Store, containment, owner, create date, log reuse wait
- used space inside data files, file growth settings

On Linux targets the version comes from the package manager, the edition from the SQL Server errorlog, and database files from the data directory; the same fields as above stay empty.

## Important architecture note

The collector does not connect to SQL Server. It needs no SQL username or password and no SQL permissions, only the WinRM/WMI (Windows) or SSH (Linux) access already used for the other inventory. `SQLConnectionOK` now means "engine metadata was collected through WMI/registry".

Named instances use instance-specific performance-counter class names; if none is found, database names and sizes fall back to the `.mdf`/`.ldf` files in the data directories.

## Network prerequisites

The central machine must be able to establish PowerShell Remoting to each target:

```powershell
Test-WSMan SQLVM01
```

The remote account needs:
- PowerShell Remoting/WinRM access
- WMI/CIM access
- Read access to the SQL Server data/log directories and registry keys

## Output

Each run creates:

```text
output/
  sql-inventory-YYYYMMDD-HHMMSS.html
  sql-inventory-YYYYMMDD-HHMMSS.json
  sql-inventory-instances-YYYYMMDD-HHMMSS.csv
  sql-inventory-databases-YYYYMMDD-HHMMSS.csv
  sql-inventory-YYYYMMDD-HHMMSS.log
```

Open the HTML file in a browser for the dashboard.

## Optional

Skip database queries:

```powershell
.\Get-SqlServerInventory.ps1 `
    -InputFile ..\config\config.json `
    -SkipDatabaseDetails
```

Skip network adapter discovery:

```powershell
.\Get-SqlServerInventory.ps1 `
    -InputFile ..\config\config.json `
    -SkipNetworkDetails
```
