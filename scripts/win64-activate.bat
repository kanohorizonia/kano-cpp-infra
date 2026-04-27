@echo off
:: Prepend pixi global bin so that `bash` in all win-64 pixi tasks resolves to
:: Git Bash (%USERPROFILE%\.pixi\bin\bash.exe) instead of C:\Windows\System32\bash.exe (WSL).
if exist "%USERPROFILE%\.pixi\bin\bash.exe" (
    set "PATH=%USERPROFILE%\.pixi\bin;%PATH%"
)
