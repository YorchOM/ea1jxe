@echo off
rem Despliega este proyecto en serviyorch. Ensena antes lo que cambia y pide confirmacion.
rem Desde consola admite las opciones de deploy.sh (--ver, --build, --borrar-sobrantes).
setlocal
cd /d "%~dp0"
set "GITBASH=%ProgramFiles%\Git\bin\bash.exe"
if not exist "%GITBASH%" set "GITBASH=bash"
if "%~1"=="" (
  "%GITBASH%" ./deploy.sh --preguntar
) else (
  "%GITBASH%" ./deploy.sh %*
)
echo.
pause
