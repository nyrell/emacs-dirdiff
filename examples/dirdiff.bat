@echo off
rem dirdiff.bat -- compare two files or directories in Emacs, like meld.
rem
rem   dirdiff LEFT RIGHT
rem
rem Run it from emacs-dirdiff\examples, or copy it to a folder on your
rem PATH and set DIRDIFF_DIR to the emacs-dirdiff folder (no trailing \).
rem runemacs.exe (in Emacs's bin folder) must be on your PATH; set
rem DIRDIFF_EMACS to use another one.  Emacs exits when the comparison
rem is quit.

setlocal
if "%~2"=="" (
  echo usage: dirdiff LEFT RIGHT
  exit /b 2
)
if not defined DIRDIFF_DIR set "DIRDIFF_DIR=%~dp0.."
if not defined DIRDIFF_EMACS set "DIRDIFF_EMACS=runemacs.exe"

start "" "%DIRDIFF_EMACS%" -L "%DIRDIFF_DIR%" --eval "(require 'dirdiff)" -f dirdiff-command-line "%~f1" "%~f2"
