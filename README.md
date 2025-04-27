PSADT files taken from hash-e219789:
https://github.com/PSAppDeployToolkit/PSAppDeployToolkit/actions/runs/14594493748

Bug #1 - If you use `LogToSubfolder = $true` in config.psd1 *AND* rename the front script (Invoke-AppDeployToolkit.ps1), the setting of $adtSession.LogTempFolder by PSADT does not happen.
- To see this, Comment out my 2 `Invoke-MergeNRollLogs` lines in the Front Script and use debug in VsCode.
- this might also be breaking the ability to expand $Env:Vars from Config.psd1

.

Bug #2 (but a Feature for me!) 
- This makes it possible for my `Invoke-MergeNRollLogs -PreOpenSession` to set $adtSession.LogTempFolder which makes LogToSubfolder work again!!
- This ONLY works if you run the front script PS1 directly in VsCode elevated.
- A PSADT log file is created along with 2 other files and the are merged and rolled as I require them to be :)

.

Bug #2b It works with PSADT_EXE_BUG.cmd to call the renamed Front script PS1 interactively and elevated
- But the log file rolling fails for some reason. (I'll have to chase that one)

.

Bug #3 - When you double-click a *renamed* EXE (to call the renamed matching PS1):
- You get a UAC prompt to run elevated
- EXE log file is NOT get created in C:\Windows\Logs
- EXE Log file is created in C:\ProgramData\Logs
- EXE log file mentions: Requires Admin: [True]		(correct)
- No PSADT log file is created
- PSADT IS launched but dies midway due to lack of Elevation

.

Bug #4 - When you run a renamed EXE Elevated using a right-click (to call the renamed matching PS1):
- You get a UAC prompt to run elevated
- EXE Log file is created in C:\Windows\Logs\
- EXE log file mentions: Requires Admin: [False]		(NOT CORRECT! both Config.psd1 files say Requires Admin = $true )
- No PSADT log file is created
- PSADT IS launched but dies midway due to lack of Elevation 

.

Bug #4b - If you launch the renamed EXE with parameters (PSADT_EXE_BUG_EXE_Interactive.cmd Elevated using a right-click) 
- You get a UAC prompt to run elevated
- EXE Log file is created in C:\Windows\Logs\
- EXE log file mentions: Requires Admin: [False]		(NOT CORRECT! both Config.psd1 files say Requires Admin = $true )
- No PSADT log file is created
- PSADT is NOT launched at all.
