; Shotate was called Snapmark before 0.12, with its own install folder and uninstall entry. Carry
; over Open at login, then remove the old app so only one copy runs.
!macro NSIS_HOOK_PREINSTALL
  ReadRegStr $0 HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Snapmark"
  StrCmp $0 "" +2 0
    WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Run" "Shotate" '"$INSTDIR\shotate.exe" --autostart'
  nsExec::Exec 'taskkill /F /IM snapmark.exe'
  IfFileExists "$LOCALAPPDATA\Snapmark\uninstall.exe" 0 +3
    ExecWait '"$LOCALAPPDATA\Snapmark\uninstall.exe" /S _?=$LOCALAPPDATA\Snapmark'
    RMDir /r "$LOCALAPPDATA\Snapmark"
!macroend
