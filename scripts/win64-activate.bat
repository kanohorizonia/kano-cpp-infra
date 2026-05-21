@echo off
setlocal EnableExtensions

:: Prepend pixi global bin so that `bash` in all win-64 pixi tasks resolves to
:: Git Bash (%USERPROFILE%\.pixi\bin\bash.exe) instead of C:\Windows\System32\bash.exe (WSL).
:: Guard against repeated prepend across nested pixi/launcher invocations, which can
:: inflate PATH and break vcvars command invocation on Windows (input line too long).
if exist "%USERPROFILE%\.pixi\bin\bash.exe" (
    if /I not "%KANO_PIXI_BIN_PREPENDED%"=="1" (
        set "PATH=%USERPROFILE%\.pixi\bin;%PATH%"
        set "KANO_PIXI_BIN_PREPENDED=1"
    )
)

endlocal & set "PATH=%PATH%" & set "KANO_PIXI_BIN_PREPENDED=%KANO_PIXI_BIN_PREPENDED%"
