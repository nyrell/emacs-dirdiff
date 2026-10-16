@echo off
rem dirdiff.bat -- compare two files or directories in Emacs, like meld.
rem
rem   dirdiff LEFT RIGHT
rem
rem Your Emacs init must load dirdiff (see dirdiff-init.el), and
rem runemacs.exe (in Emacs's bin folder) must be on your PATH.  Copy
rem this file to a folder on your PATH.  A new Emacs starts and exits
rem when the comparison is quit.

if "%~2"=="" (
  echo usage: dirdiff LEFT RIGHT
  exit /b 2
)

start "" runemacs.exe -f dirdiff-command-line "%~f1" "%~f2"
