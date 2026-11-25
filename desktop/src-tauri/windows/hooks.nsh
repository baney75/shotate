; Yapshot was called Shotate, and Snapmark before that, each with its own install folder and
; uninstall entry. Carry over Open at login, then remove the old app so only one copy runs. An
; update from Shotate runs this installer silently and can't start the new app itself, so the
; installer starts it.
Var ReplacedOldApp

!macro NSIS_HOOK_PREINSTALL
  StrCpy $ReplacedOldApp ""
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Snapmark"
  StrCmp $0 "" +2 0
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Yapshot" '"$INSTDIR\yapshot.exe" --autostart'
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Shotate"
  StrCmp $0 "" +2 0
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Yapshot" '"$INSTDIR\yapshot.exe" --autostart'
  ; Copied once: a later update must not turn Open at login back on.
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Snapmark"
  DeleteRegValue HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Shotate"
  nsExec::Exec 'taskkill /F /IM snapmark.exe'
  Pop $0
  nsExec::Exec 'taskkill /F /IM shotate.exe'
  Pop $0
  IfFileExists "$LOCALAPPDATA\Snapmark\uninstall.exe" 0 +3
    ExecWait '"$LOCALAPPDATA\Snapmark\uninstall.exe" /S _?=$LOCALAPPDATA\Snapmark'
    RMDir /r "$LOCALAPPDATA\Snapmark"
  IfFileExists "$LOCALAPPDATA\Shotate\uninstall.exe" 0 +4
    ExecWait '"$LOCALAPPDATA\Shotate\uninstall.exe" /S _?=$LOCALAPPDATA\Shotate'
    RMDir /r "$LOCALAPPDATA\Shotate"
    StrCpy $ReplacedOldApp "1"
!macroend

!macro NSIS_HOOK_POSTINSTALL
  IfSilent 0 +3
  StrCmp $ReplacedOldApp "1" 0 +2
    Exec '"$INSTDIR\yapshot.exe"'
!macroend
