# Change Log - Hyper-V Automation Lab Deploy

## 2026-07-13 Script Renaming Update
- **File(s) modified:**
  - `README.md`
  - `CHANGES.md`
  - `Instructions.ps1`
  - `PDF-README.txt`
  - `backup.donottouch`

- **What changed:**
  - Updated all references from old script name (`1.0.2.ps1`, `Gen1.0.2.ps1`) to current main script name (`Begin.ps1`)
  - Fixed version numbering in CHANGES.md (removed "Gen" prefix from version names)
  - All PowerShell command examples now correctly use `.\Begin.ps1`

- **Reason:**
  - The main deployment script was renamed to `Begin.ps1` but documentation still referenced the old name
  - Documentation needed to accurately reflect the current script name for users

---

## Previous Changes (from CHANGES.md)
See `CHANGES.md` for historical changes including:
- DC Promotion Idempotency fix
- DNS Forward/Reverse Lookup Zones enhancement
- VM Configuration (CPU/Memory) with Persistence
