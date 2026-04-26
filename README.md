# WoW Server Launcher

A graphical desktop launcher for self-hosted World of Warcraft servers built on PowerShell + WPF. Manage all your server processes, databases, accounts, and backups from a single polished interface — no command line required.

![PowerShell 5.1](https://img.shields.io/badge/PowerShell-5.1-blue?logo=powershell)
![Platform](https://img.shields.io/badge/Platform-Windows%2010%2F11-0078D4?logo=windows)
![License](https://img.shields.io/badge/License-GPL--2.0-blue)

---

## Supported Server Cores

| Version | Core | Auth Process | World Process |
|---------|------|-------------|---------------|
| **AzerothCore** | [AzerothCore](https://www.azerothcore.org) | `authserver.exe` | `worldserver.exe` |
| **TrinityCore** | [TrinityCore](https://www.trinitycore.org) | `bnetserver.exe` | `worldserver.exe` |
| **CMaNGOS** | [CMaNGOS](https://cmangos.net) | `realmd.exe` | `mangosd.exe` |

> Each core has its own launcher folder. The interface is identical across all versions — only the underlying process names, config file paths, and database schemas differ.

---

## Features

- **Dashboard** — real-time status indicators, one-click server launch/stop, embedded server consoles
- **Server Manager** — individual control over each server process (Database, Auth, World, Website)
- **Saves Manager** — full database backup and restore with named slots
- **Account Manager** — create, edit, change password, and delete player accounts directly from the UI
- **Settings** — realm name editor, MySQL connection display, config file shortcuts, and tools
- **Maintenance** — install prerequisites, create desktop shortcuts, check for updates
- **Theme Selector** *(CMaNGOS only)* — three built-in color themes with per-theme application icon

---

## Requirements

| Requirement | Notes |
|-------------|-------|
| **Windows 10 / 11** | 64-bit recommended |
| **PowerShell 5.1** | Included with Windows — no installation needed |
| **.NET Framework 4.x** | Included with Windows — required for WPF |
| **WoW Server** | A pre-compiled server with MySQL, server binaries, and database already set up |

> The launcher does **not** set up a WoW server from scratch. It is a management tool for an already working pre-compiled server.

---

## Folder Structure

The launcher expects this layout inside your server root folder:

```
[Server Root]/
├── Launcher.bat                    ← Double-click to start the launcher
├── Database/
│   ├── MySQL_Server.bat            ← MySQL startup script
│   └── bin/
│       └── mysql.exe               ← MySQL client (used internally)
├── Servers/
│   ├── authserver.exe              ← Auth server binary  (AzerothCore)
│   ├── worldserver.exe             ← World server binary (AzerothCore / TrinityCore)
│   ├── bnetserver.exe              ← BNet server binary  (TrinityCore)
│   ├── realmd.exe                  ← Auth server binary  (CMaNGOS)
│   ├── mangosd.exe                 ← World server binary (CMaNGOS)
│   └── configs/  (or Servers/)
│       ├── authserver.conf
│       ├── worldserver.conf
│       ├── bnetserver.conf
│       ├── realmd.conf
│       └── mangosd.conf
├── Website/
│   └── Apache/
│       └── Apache_Server.bat       ← Web server startup script (optional)
├── Saves/                          ← Database backup slots (auto-created)
├── Logs/                           ← Server log files
└── Tools/
    ├── HeidiSQL/
    │   └── heidisql.exe            ← Database management tool (optional)
    ├── Notepad/
    │   └── notepad++.exe           ← Text editor for config files (optional)
    └── Launcher/
        ├── Icons/                  ← .ico files for the launcher window
        ├── Connections/
        │   ├── connection_auth.cnf       ← MySQL credentials for auth DB
        │   └── connection_characters.cnf ← MySQL credentials for characters DB
        ├── Themes/                 ← CMaNGOS only — color theme presets
        │   ├── Exp1.txt
        │   ├── Exp2.txt
        │   └── Exp3.txt
        └── Scripts/
            ├── Launcher.ps1        ← Main launcher script
            ├── Directories.txt     ← Server executable paths
            ├── MySQL.txt           ← MySQL connection settings
            ├── Theme.txt           ← Active theme selector (CMaNGOS only)
            ├── Name.txt            ← Server name shown in the sidebar
            ├── AppName.txt         ← Window title bar text
            ├── Version.txt         ← Version string shown in the sidebar
            └── Updates.txt         ← URL for the "Check for Updates" button
```

---

## Quick Start

1. **Run the launcher** — double-click `Launcher.bat` in the server root. If Windows asks for permission, click *Run anyway* (the script is not signed).

2. **Start your servers** — from the **Dashboard**, click **Launch Servers** to start Database → Auth → World in sequence. Or use **Server Manager** to start them individually.

3. **Wait for the consoles** — the embedded server windows appear inside the Dashboard once each process opens its main window. This can take 30 seconds to several minutes for the World server on first boot.

4. **Check the status dots** — green means running, red means stopped. The realm name appears below the Dashboard title when the database is online.

> **Tip:** Start everything in order — Database first, then Auth, then World. The launcher's *Launch Servers* button does this automatically with built-in delays.

---

## Configuration Files

All configuration is done by editing plain text files inside `Tools\Launcher\Scripts\`. You can edit them manually with any text editor, or use the shortcuts in the **Settings** and **Maintenance** sections.

### `Directories.txt` — Server Paths

Defines where each executable is located. Paths can be **relative** to the server root or **absolute**.

```ini
MySQL        = Database\MySQL_Server.bat
Auth         = Servers\authserver.exe             # authserver / bnetserver / realmd
World        = Servers\worldserver.exe            # worldserver / mangosd
Website      = Website\Apache\Apache_Server.bat
HeidiSQL     = Tools\HeidiSQL\heidisql.exe
Notepad      = Tools\Notepad\notepad++.exe
ConfigFolder = Servers\configs                    # folder opened by "Folder" button in Settings
LogsFolder   = Logs                               # folder opened by "Server Logs" button
AuthConf     = Servers\configs\authserver.conf
WorldConf    = Servers\configs\worldserver.conf
```

> If a path does not exist the corresponding button is simply disabled — the launcher will not crash.

### `MySQL.txt` — Database Connection

Used to display connection info in the **Settings** page and to pre-fill the HeidiSQL shortcut.

```ini
Host        = 127.0.0.1
Port        = 3306
User        = root
Password    = 123456
Description = AzerothCore
```

> The launcher connects to MySQL using the credentials stored in `Tools\Launcher\Connections\connection_auth.cnf`. That file is a standard MySQL options file (`[client]` section) and is separate from `MySQL.txt`.

### `connection_auth.cnf` — MySQL Client Credentials

Located in `Tools\Launcher\Connections\`. Used internally for all database queries (account management, realm name, saves).

```ini
[client]
user     = root
password = 123456
host     = 127.0.0.1
port     = 3306
database = auth          # or classicrealmd for CMaNGOS
```

### `Name.txt` — Sidebar Title

The server name displayed at the top of the left navigation sidebar.

```
AzerothCore
```

### `AppName.txt` — Window Title

The text shown in the title bar of the launcher window.

```
WoW Server Launcher
```

### `Version.txt` — Version Label

A small version string shown at the bottom of the sidebar.

```
WoW Server Launcher vX.X
```

---

## Sections In Detail

### Dashboard

The main page. Shows at a glance whether each server is running and allows launching or stopping all servers at once.

- **Status pills** — colored dots (green = running, red = stopped) for Database, Auth, World, and Website
- **Launch Servers** — starts Database → Auth → World (and optionally Website) in sequence with built-in delays
- **Shut Down All** — gracefully stops all servers
- **Embedded consoles** — the server terminal windows are embedded directly inside the Dashboard. You can type commands into the World console from within the launcher

> The realm name appears as a subtitle below "Dashboard" once MySQL is online.

---

### Server Manager

Gives you individual control over each server process.

- **Start / Stop / Restart** buttons per server (Database, Auth, World, Website)
- **Start All / Stop All** bulk actions
- Each row shows the process name and current status

---

### Saves Manager

Back up and restore your entire server database with a single click.

- **10 save slots** — each slot stores a full dump of both the auth and characters databases
- **Save** — exports both databases to the selected slot (existing save is overwritten)
- **Load** — imports both databases from the selected slot *(server must be stopped first)*
- **Delete** — removes the save files for a slot
- Each slot shows its **name** and the **date/time** it was created

> Saves are stored in `[Server Root]\Saves\<slot number>\` as `auth.sql` and `characters.sql`.

---

### Account Manager

Manage player accounts without touching the database directly.

| Action | What it does |
|--------|-------------|
| **New Account** | Creates an account with a username, password, email, and GM level |
| **Change Password** | Updates the SRP6 verifier so the new password works immediately |
| **Edit Account** | Changes username, email, or GM level |
| **Delete Account** | Removes the account and all associated data (characters, bans, etc.) |

**GM Levels:**

| Level | Name | Description |
|-------|------|-------------|
| 0 | Player | Normal player — no special permissions |
| 1 | Moderator | Can use basic in-game moderation commands |
| 2 | Game Master | Full GM toolkit |
| 3 | Administrator | Server administrator access |

> Passwords are stored using the WoW SRP6 protocol. The launcher computes the correct hash — you never store a plain-text password.

---

### Settings

**MySQL Connection** — shows the connection parameters from `MySQL.txt` (read-only display).

**Realm Name** — edit and apply the realm name that appears in the in-game server list and on the Dashboard. Changes are written directly to the `realmlist` table in the database.

**Configuration Files** — quick buttons to open the Auth config, World config, and the config folder directly in Notepad++.

**Tools** — shortcut buttons for HeidiSQL (database browser) and the server logs folder.

**Launcher Theme** *(CMaNGOS only)* — see [Theme System](#theme-system-cmangos-only) below.

---

### Maintenance

**Install Visual C++ Redistributable** — runs the official Microsoft VC++ Redist installer (x86 + x64). Required if the server binaries show DLL errors on first launch.

**Create Desktop Shortcut** — creates a shortcut to `Launcher.bat` on your Desktop, using the current theme's icon.

**Check for Updates** — opens the URL defined in `Updates.txt` in your browser.

---

## Theme System *(CMaNGOS only)*

The CMaNGOS launcher includes a built-in theme selector accessible from the **Settings** page. Three presets are available, each with its own color palette and application icon.

| Theme | Key | Accent Color | Icon |
|-------|-----|-------------|------|
| **Classic** | `Exp1` | Gold / Yellow | `Launcher_Exp1.ico` |
| **The Burning Crusade** | `Exp2` | Green | `Launcher_Exp2.ico` |
| **Wrath of the Lich King** | `Exp3` | Blue | `Launcher_Exp3.ico` |

### Changing the Theme

**From the launcher:** Go to **Settings → Launcher Theme**, click **Apply Theme** on the desired card, confirm the dialog. Restart the launcher to see the new colors.

**Manually:** Open `Tools\Launcher\Scripts\Theme.txt` and change the `ActiveTheme` value:

```ini
ActiveTheme = Exp1   # Classic
ActiveTheme = Exp2   # The Burning Crusade
ActiveTheme = Exp3   # Wrath of the Lich King
```

### Customizing a Theme

Each theme is a plain text file in `Tools\Launcher\Themes\`. Open `Exp1.txt`, `Exp2.txt`, or `Exp3.txt` with any text editor and adjust the values. Changes take effect after restarting the launcher.

```ini
# Background colors
BgWindow  = #313338    # Main window background
BgSidebar = #1E1F22    # Left sidebar background
BgCard    = #2B2D31    # Card / panel background

# Accent colors
AccentGreen    = #C8960C   # Primary button background
AccentGreenAlt = #A07808   # Button hover / confirm dialog
AccentBlue     = #FFD100   # Text accent (app name, selected nav, cursor)

# Console color (two hex digits: background + foreground)
ConsoleColor = 0E          # 0 = black bg, E = yellow text

# Application icon (file must exist in Tools\Launcher\Icons\)
AppIcon = Launcher_Exp1.ico
```

**Color format:**
- `#RRGGBB` — solid color (e.g. `#FFD100`)
- `#AARRGGBB` — with transparency (`AA`: `00` = invisible, `FF` = opaque)

**Console color codes:**

```
0=Black     1=DarkBlue     2=DarkGreen   3=DarkCyan
4=DarkRed   5=DarkMagenta  6=DarkYellow  7=Gray
8=DarkGray  9=Blue         A=LightGreen  B=LightCyan
C=LightRed  D=Magenta      E=Yellow      F=White
```

Example: `ConsoleColor = 0A` → black background + light green text.

---

## Troubleshooting

### The launcher opens and immediately closes

PowerShell execution policy may be blocking the script. Open PowerShell as Administrator and run:

```powershell
Set-ExecutionPolicy -Scope CurrentUser -ExecutionPolicy RemoteSigned
```

Then try running `Launcher.bat` again.

---

### "XAML Error" dialog on startup

A syntax error was introduced in `Launcher.ps1` (usually by a manual edit). Restore the file from a backup or re-download the launcher.

---

### Status dots are all red / servers won't start

1. Check that the paths in `Directories.txt` are correct and the files actually exist.
2. Make sure MySQL is running before starting Auth or World — the launcher's *Launch Servers* button handles this automatically.
3. Check `Logs\` for server-side errors.

---

### The realm name doesn't appear on the Dashboard

The Dashboard subtitle only shows the realm name when MySQL is online. If it still doesn't appear after MySQL starts, verify that `connection_auth.cnf` has the correct credentials and that the `realmlist` table exists and contains at least one row.

---

### The embedded console is blank or mispositioned

- Resize the launcher window slightly — the console repositions itself on every layout update.
- Make sure the server process has fully opened its main window. Very large world servers can take several minutes before the console window appears.

---

### Account creation fails silently

- Confirm MySQL is running and the credentials in `connection_auth.cnf` are correct.
- Check that the `database` field in `connection_auth.cnf` matches your auth database name (`auth` for AzerothCore/TrinityCore, `classicrealmd` for CMaNGOS).

---

### HeidiSQL or Notepad++ buttons do nothing

The paths in `Directories.txt` for `HeidiSQL` and `Notepad` do not exist. Update them to point to your actual installation paths, or install the tools in the expected `Tools\` subfolder.

---

## Differences Between Versions

| Feature | AzerothCore | TrinityCore | CMaNGOS |
|---------|:-----------:|:-----------:|:-------:|
| Auth process | `authserver.exe` | `bnetserver.exe` | `realmd.exe` |
| World process | `worldserver.exe` | `worldserver.exe` | `mangosd.exe` |
| Auth database | `auth` | `auth` | `classicrealmd` |
| Characters database | `characters` | `characters` | `classiccharacters` |
| Config folder | `Servers\configs\` | `Servers\` | `Servers\` |
| Theme system | — | — | ✔ (3 presets) |
| Per-theme icon | — | — | ✔ |
| SRP6 format | Standard | Standard | Big-endian hex |
| `account_access` table | ✔ | ✔ | — (gmlevel on account) |

---

*Built with PowerShell 5.1 + WPF (.NET Framework). No external dependencies required beyond a standard Windows installation.*
