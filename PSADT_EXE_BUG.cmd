@ECHO OFF
::This makes the CMD call the PS1 matching it's basename.
:: LAUNCH ELEVATED!!
TITLE Installing %~n0

setlocal
setlocal enableextensions
setlocal enabledelayedexpansion

::: GLOBAL VARIABLES
::: -----------------------------------------------------------------------------------------------
::
:GlobalVariables
:: If this is the _Remove wrapper uncomment the two rem lines below.
set "_ERR=0"

set "_PACKAGENAME=%~n0"
set "_PACKAGENAME=%_PACKAGENAME:_Remove=%"
set "_SOURCEMEDIADIR=%~dp0"
REM Trim off Last char ( \ ) (Was breaking log rolling in MergeNRollLogs ?!?!)
Set "_SOURCEMEDIADIR=%_SOURCEMEDIADIR:~0,-1%"


set "_DEFAULTPARAM=-DeploymentType "Install" -DeployMode "Interactive""
::set "_DEFAULTPARAM=-DeploymentType "Uninstall" -DeployMode "NonInteractive""
set "_ADDITIONALPARAMS=%*"

:: Force 64-bit PowerShell.
set "_SYSROOTCORE=system32"
if exist "%SYSTEMROOT%\Sysnative\" (
	echo Running 32bit CMD on 64bit OS.
	echo Getting 64bit versions.
	set "_SYSROOTCORE=Sysnative"
)
set "_POWERSHELL=%SYSTEMROOT%\%_SYSROOTCORE%\WindowsPowerShell\v1.0\powershell.exe"
)


:: Execute PowerShell script.
:: CAVEAT: we may get the wrong exit code in PowerShell 2 (e.g.syntax error = ERRORLEVEL 0 )
:: and if Exit code is higher than 65536, CMD *MAY* roll over the exit code before it becomes an ERRORLEVEL.

echo ---------------------------------------------
	"%_POWERSHELL%" -ExecutionPolicy Bypass -File "%_SOURCEMEDIADIR%\%_PACKAGENAME%.ps1" %_DEFAULTPARAM% %_ADDITIONALPARAMS%
	set "_ERR=%ERRORLEVEL%"
	echo PSADT returned an error code [%_ERR%].

echo ---------------------------------------------


if %_ERR% NEQ 0 ( color 4f )
echo Script '%_CMDFILE%' completed with return code [%_ERR%].
%_TIMEOUT% /t 5 > nul 2>&1
color
exit /b %_ERR%
:::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::::