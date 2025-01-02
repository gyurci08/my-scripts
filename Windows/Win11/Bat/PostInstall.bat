# Disable Windows Update service
sc config wuauserv start= disabled
net stop wuauserv

sc config SysMain start= disabled
net stop SysMain

# Disable Windows 11 Widgets
reg add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /f /ve

# Enable OneDrive file sync
reg add "HKEY_LOCAL_MACHINE\Software\Policies\Microsoft\Windows\OneDrive" /t REG_DWORD /v DisableFileSyncNGSC /d 0 /f

# Restart Windows Explorer to apply changes
taskkill /f /im explorer.exe
start explorer.exe