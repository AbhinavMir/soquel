# Security model

Plain language, no hedging.

## What Soquel does

It reads and writes files on your Mac, as you, using the standard macOS file APIs.

## What it does not do

- No account, sign-in, licence key, trial, or activation — nothing to check, so nothing is checked
- No network connection of any kind — it makes no requests, and there is no server
- No telemetry, analytics, crash reporting, or usage counting
- No file contents leave the device, ever
- No background daemon, no login item, no privileged helper

## Permissions

Soquel asks for nothing at install. macOS itself prompts the first time you open a protected
folder (Desktop, Documents, Downloads, or an external volume). Granting Full Disk Access in System
Settings stops those prompts; it is optional and Soquel works without it, showing an error for
folders it cannot read.

## Deleting files

Delete goes to the Trash and is undoable. Permanent delete always asks first and cannot be undone —
that confirmation is on by default and there is no preference to remove it in 0.1.

A copy or move that would overwrite something always asks. Choosing Replace writes the incoming
item beside the existing one and swaps it in only after the write succeeds, so a failure never
leaves you with neither file.

## Running other programs

Soquel launches other applications in two places: Open in Terminal and Open in Editor. Both use
`NSWorkspace` with the folder or file as an argument. Soquel does not build shell command strings
and does not run a shell, so a filename cannot be interpreted as a command.

The Copy Shell-Escaped Path command wraps the path in single quotes and escapes embedded quotes. It
copies text to your clipboard; it does not execute anything.

There is no plugin or script system in 0.1. Nothing in the app executes code from disk.

## Where settings live

Preferences, favourites, and the restored session are stored in standard `UserDefaults` under
`app.soquel.Soquel`. They contain folder paths and view settings, nothing else.

## Reporting a problem

Open an issue. If it is a security problem, say so in the title and describe the impact and the
steps to reproduce.
