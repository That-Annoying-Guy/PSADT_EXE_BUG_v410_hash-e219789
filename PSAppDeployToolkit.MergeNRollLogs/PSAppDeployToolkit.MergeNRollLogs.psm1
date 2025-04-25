<#
.SYNOPSIS
PSAppDeployToolkit.MergeNRollLogs handles Log Merging/zipping and Rolling of PSADT log files

.DESCRIPTION
By default, PSADT will overwrite conflicting log files. This module extends PSADT's logging capability to merge and roll log files.
While you can use this MergeNRollLogs module to only rotate PSADT's log file, it is meant to be used with PSADT's LogToSubfolder feature.
LogToSubfolder is a temporary logging folder where ALL the log files you want to be grouped together are thrown into during a session.
You can copy or send all the logs files you want there during a PSADT session. (We go as far as doing a mini inventory!)
At the end of the session, we either compress them into a ZIP file or merge them into one massive log file.
The "one massive log" option can merges CMTrace log files too but treats them as legacy text log files.
You can configure this MergeNRollLogs module in PSADT's \Config\Config.psd1 in a NEW MergeNRollLogs section.

This happens REGARDLESS if the PSADT session was successful or not.
If the powershell session end abruptly, however, the temporary logging folder will remain.
If another attempt of the same package is started and the temporary logging folder of the previous session exist, this module will process them before the new session starts.



Logging of "loghandling"
We record what is done to the log in a "loghandling" log file in %temp%\$($adtSession.InstallName)_LogHandling_<Random>.log
By default, if all goes well, this temporary log file is deleted.
If Toolkit.LogHandlingDebug = $true in Config.psd1, the "loghandling" log file is NOT DELETED and post all messages to the screen during log handling.

CAVEAT:
Modifications to Invoke-AppDeployToolkit.ps1 are required.
This module is imported *explicitly* in Invoke-AppDeployToolkit.ps1 before the the PSADT session is opened with Open-ADTSession.
Throughout this module, the Invoke-AppDeployToolkit.ps1 script will also be refered to as the "Front Script" because it can be renamed.


PSAppDeployToolkit is licensed under the GNU LGPLv3 License - (C) 2024 PSAppDeployToolkit Team (Sean Lillis, Dan Cunningham, Muhammad Mashwani, Mitch Richters, Dan Gough).

This program is free software: you can redistribute it and/or modify it under the terms of the GNU Lesser General Public License as published by the
Free Software Foundation, either version 3 of the License, or any later version. This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
for more details. You should have received a copy of the GNU Lesser General Public License along with this program. If not, see <http://www.gnu.org/licenses/>.

.NOTES
All the functions in this module use the Write-TempLog function in this module.

If Zipping is chosen, this module will use its own Merge-ToOneZipFile function to perform the zipping because PSADT functions could change the log files.

Log handling occur at 2 places:
-Before the PSADT session opens, before logging is possible
-In the Close-ADTSession Function using CallBacks (New in PSADT V4)

1- We can access $ADTSession variable before AppDeployToolkit.psm1 does because it is created in the Front Script before any modules are imported.
2- We read the \Config\Config.psd1 file to avoid setting variables in different places
    We use the native Import-PowerShellDataFile cmdlet 
    If the ($($adtSession.DeploymentType) -eq "Uninstall" ), we also append _Remove to the log name.
3- We clean up log files leftover from a previous run that would conflict with the current run of PSADT. 
4- If RotateLogFiles -eq $true, we roll the log files using the Invoke-LogfileRotation function (We use the Alias Rotate-Logfiles).


*In PSADT V4's Close-ADTSession function (PKA Exit-Script), there are 2 callback types: $Script:ADT.Callbacks.Closing and $Script:ADT.Callbacks.Finishing
$Script:ADT.Callbacks.Finishing seems to be the one we need because it occurs just before PSADT ends.
CAVEAT: As implemented in v4.0.5, if ANY errors occur and reach the Close-ADTSession function, it will create a log entry!

TODO:
-use Mitch method to expand Variables from Config.psd1
-Determine if who wins when Log handling goes bad: does PSADT processes the fault or this module's Exit-ScriptLogHandling
-Try to remove Custom ExitCodes and use Throw instead with the Error trick used in PSADT
-Replace test-path with [System.IO.File]::Exists($DestinationPath) (6x faster!!!)
-MAYBE Replace test-path with [System.IO.DIRECTORY]::Exists($DestinationPath) if faster
-replace -ContinueOnError with -ErrorAction (Cannot -ErrorAction is a reserved parameter, will need to ask how they do it)

secret feature:
Only PS modules whos names start with PSAppDeployToolkit. will be imported automatically by PSADT when the session is opened.

.LINK
https://psappdeploytoolkit.com

#>

##*===============================================
##* MARK: MODULE GLOBAL SETUP
##*===============================================

# Set strict error handling across entire module.
$ErrorActionPreference = [System.Management.Automation.ActionPreference]::Stop
$ProgressPreference = [System.Management.Automation.ActionPreference]::SilentlyContinue
Set-StrictMode -Version 1

##*===============================================
##* MARK: FUNCTION LISTINGS
##*===============================================

#-----------------------------------------------------------------------------
# MARK: Invoke-LogfileRotation
#-----------------------------------------------------------------------------
Function Invoke-LogfileRotation {
    <#
    .SYNOPSIS
        Rotates Log or ZIP'd Log files
    .DESCRIPTION
        We then roll the log files.
        If the one massive log option is selected (LogCompressFormat = '.Log')
        Merged log files will end with .log .bk1 .bk2 ... .bk9
        Merged removal log file will end with _Remove.log _Remove.bk1 ... _Remove.bk9
        Merged repair log file will end with _repair.log _repair.bk1 ... _repair._bk9   [TODO: Untested]

        If the ZIP option is selected (LogCompressFormat = '.Zip') [TODO: Confirm names]
        Zipped log files will end with .Zip _bk1.Zip _bk2.Zip ... _bk9.Zip
        Zipped removal log files will end with _Remove.Zip _Remove_bk1.Zip ... _Remove_bk9.Zip
        Zipped repair log files will end with _Repair.Zip _Repair_bk1.Zip ... _Repair_bk9.Zip  [TODO: Untested]

        Unlike other log file rolling schemes: 
        - The log/Zip file is renamed once.
        - Files get overwritten only when they are the oldest out of the set. (10 max)
        - The advantage of this log rolling scheme is that the filenames do not change.
        (E.g.: If log file .bk4 is the "bad" one, you can run the script a few times and
        .bk4 is still the "bad" one, it doesn't become .bk5 or .bk7 later on.)
        Creates	.bk# for .log files (for backward compatibility)
        Creates .bk#.zip for .zip files (Need to end with .zip or it breaks file associations)
    .PARAMETER logFileNameToRotate
        Filename of the unrolled log file
    .PARAMETER LogFileParentFolder
        path to the directory holding the log file (Defaults to $LogPath)
        This is also the destination of the rolled files
    .PARAMETER ConfigMaxNumOfBkLogFiles
        Number of backups to keep. Defaults to 9 backups
        FYI: 9 actually means 10 log files: 9 .bk# backups plus the most current .log
    .EXAMPLE
        Rotate-Logfiles -LogFileNameToRotate <path to logfile.log>
    .EXAMPLE
        Rotate-Logfiles -LogFileNameToRotate <path to logfile.zip>
    .EXAMPLE
        Rotate-Logfiles -LogFileNameToRotate $DestinationArchiveFileName -LogFileParentFolder $LogPath
    .NOTES
        CAVEAT: We cannot use Write-ADTLogEntry in this function because it would change log files. Uses Write-TempLog instead
        TODO: Try to remove Custom ExitCodes and use Throw instead
    #>
        [CmdletBinding()]
        Param(
            [Parameter(Mandatory = $true,HelpMessage='filename of the unrolled log file')]
            [ValidateNotNullOrEmpty()]
            [string]$LogFileNameToRotate,

            [Parameter(Mandatory = $false,HelpMessage='directory containing the log files (rolled and un-rolled)')]
            [ValidateNotNullOrEmpty()]
            [string]$LogFileParentFolder = $LogPath,

            [Parameter(Mandatory = $false)]
            [ValidateNotNullOrEmpty()]
            [Int]$ConfigMaxNumOfBkLogFiles =  9		# FYI: 9 actually means 10 log files
        )
        
        ## Get the name of this function and write header
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
        
        Write-TempLog "This function was given these parameters:" -Source ${CmdletName}
        $PSBoundParameters | Out-String | Write-TempLog -Source ${CmdletName}
    
    
        [String]$LogFileToRotateFullPath = Join-Path -Path $LogFileParentFolder -ChildPath $LogFileNameToRotate
        
        If (Test-Path $LogFileToRotateFullPath) {
            #Must use Write-TempLog to "log the rolling" or else you pollute the older logs
            Write-TempLog "Rolling the log files..." -Source ${CmdletName}
            [String]$logFileExt = [System.IO.Path]::GetExtension($LogFileToRotateFullPath)  #.log or .ZIP
    
            If ($logFileExt -eq ".log"){
                [String]$logFileNameOnly = [System.IO.Path]::GetFileNameWithoutExtension($LogFileToRotateFullPath) #Get Basename.Ext only
                #Find the next LogfileName
                [Int32]$iLoopCount = 0
                do {
                    $iLoopCount++
                    #Join-Path Fails on non-existing paths (known PS v2/3/4 bug) so we do this below
                    $BKlogFullPath = "${LogFileParentFolder}\${logFileNameOnly}.bk${iLoopCount}"
                    If (Test-Path $BKlogFullPath) {	Write-TempLog "INFO: $BKlogFullPath exists" -Source ${CmdletName} }
                } until (-not (Test-Path $BKlogFullPath))
    
                Write-TempLog "INFO: [${logFileNameOnly}.bk${iLoopCount}] does NOT exists. Using that filename for new backup." -Source ${CmdletName}
                if ($iLoopCount -GT $ConfigMaxNumOfBkLogFiles) { $iLoopCount=1 } #prevents having more than $MaxNumOfBkLogFiles copies
                [string]$BKlogFullPath = "${LogFileParentFolder}\${logFileNameOnly}.bk${iLoopCount}"
                #CAVEAT: Cannot use ToolKit functions to copy/Delete/exit here or we pollute the logs we are processing
                Copy-Item -Path $LogFileToRotateFullPath -Destination $BKlogFullPath -ErrorAction SilentlyContinue 
                If ( Test-Path $BKlogFullPath ) { #only if backup was good do we clean up for new log
                    Try {	# Copy was successful, delete original
                        Remove-Item -Path $LogFileToRotateFullPath -Force -ErrorAction Stop
                        Write-TempLog "INFO: Copy was successful. Deleting original also successful." -Source ${CmdletName}
                    } Catch {
                        If (($Host.Name -eq "ConsoleHost") -and $adtConfig.Toolkit.LogWriteToHost ) { 
                            Try { cmd /c color 4f} Catch { }  #Make console screen go RED (NOTE: works in PS1 console, Fails in PowerGUI)
                        }
                        Write-TempLog "ERROR: Unable to delete old [$LogFileToRotateFullPath] file. Check if another process has it open or is `"sitting`" on it" -Source ${CmdletName} -Severity 3 -ForceToConsole
                        Write-TempLog "FYI: `"sitting on it`" means just having the file selected in Windows Explorer. " -source $CmdletName -Severity 3 -ForceToConsole
                        $exitcode = 70003	
                        Exit-ScriptLogHandling $exitcode
                    }
    
                    $iLoopCount++
                    if ($iLoopCount -GT $ConfigMaxNumOfBkLogFiles) { $iLoopCount = 1 } #prevents having more than $MaxNumOfBkLogFiles copies
                    [string]$FutureLogFullPath = "${LogFileParentFolder}\${logFileNameOnly}.bk${iLoopCount}"	#Not .ZIP here!
                    Write-TempLog "INFO: Making sure .BK${iLoopCount} does NOT exist for next run." -Source ${CmdletName}
                    Try {
                        If (Test-Path $FutureLogFullPath) {
                            Write-TempLog "INFO: Log file [$FutureLogFullPath] exists already. Must delete" -Source ${CmdletName}
                            Write-TempLog "INFO: Creating a missing .BK# for next run." -Source ${CmdletName}
                            Remove-Item -Path  $FutureLogFullPath -ErrorAction stop
                            Write-TempLog "INFO: old log file [$FutureLogFullPath] deleted. We are good for the next run of this script" -Source ${CmdletName}
                        }
                    } catch {
                        If (($Host.Name -eq "ConsoleHost") -and $adtConfig.Toolkit.LogWriteToHost ) {
                            Try { Cmd /c color 4f} Catch { }  #Make screen go RED (works in PS1 console, Fails in PowerGUI)
                        } 
                        Write-TempLog "ERROR: Unable to delete old [$FutureLogFullPath] file. Check if another process has it open or is `"sitting`" on it" -Source ${CmdletName} -Severity 3 -ForceToConsole
                        Write-TempLog "FYI: *sitting on it* means just having the file selected in Windows Explorer. " -source $CmdletName -Severity 3 -ForceToConsole
                        $exitcode = 70004
                        Exit-ScriptLogHandling $exitcode
                    }				
                    
                } Else {
                    If (($Host.Name -eq "ConsoleHost") -and $adtConfig.Toolkit.LogWriteToHost ) { 
                        Try { Cmd /c color 4f} Catch { }  #Make screen go RED (works in PS1 console, Fails in PowerGUI)
                    } 
                    Write-TempLog "ERROR: Insufficient rights to backup old [$logFileNameOnly] to [${logFileNameOnly}.bk${iLoopCount}]" -Source ${CmdletName} -Severity 3
                    $exitcode = 70005	#Note: 70005 is arbitrary at this stage.
                    Exit-ScriptLogHandling $exitcode
                }
            } elseif ($logFileExt -eq ".zip") {
                [String]$logFileNameOnly = [System.IO.Path]::GetFileNameWithoutExtension($LogFileToRotateFullPath) #Get Basename only
                #Find the next LogfileName
                [Int32]$iLoopCount = 0
                do {
                    $iLoopCount++
                    #Join-Path Fails on non-existing paths (known PS v2/3/4 bug)
                    $BKlogFullPath = "${LogFileParentFolder}\${logFileNameOnly}.bk${iLoopCount}.zip"
                    If (Test-Path $BKlogFullPath) {	Write-TempLog "INFO: $BKlogFullPath exists" -Source ${CmdletName} }
                } until (-not (Test-Path $BKlogFullPath))
    
                Write-TempLog "INFO: [${logFileNameOnly}.bk${iLoopCount}.zip] does NOT exists. Using that for new backup." -Source ${CmdletName}
                if ($iLoopCount -GT $ConfigMaxNumOfBkLogFiles) { $iLoopCount = 1 } #prevents having more than $MaxNumOfBkLogFiles copies
                [string]$BKlogFullPath = "${LogFileParentFolder}\${logFileNameOnly}.bk" + $iLoopCount + ".zip"
                #CAVEAT: cannot use ToolKit functions to copy/Delete/exit here or we pollute the old logs
                Copy-Item $LogFileToRotateFullPath $BKlogFullPath -ErrorAction SilentlyContinue
                If ( Test-Path $BKlogFullPath ) { #only if backup was good do we clean up for new log
                    Try { 	# Copy was successful, delete original
                        Remove-Item -Path $LogFileToRotateFullPath -Force -ErrorAction Stop
                        Write-TempLog "INFO: Copy was successful. Deleting original also successful." -Source ${CmdletName}
                    } Catch {
                        If (($Host.Name -eq "ConsoleHost") -and $adtConfig.Toolkit.LogWriteToHost ) { 
                            Try { cmd /c color 4f } Catch { }  #Make screen go RED (works in PS1 console, Fails in PowerGUI)
                        }
                        Write-TempLog "ERROR: Unable to delete old [$LogFileToRotateFullPath]. Check if another process has it open or is `"sitting`" on it" -Source ${CmdletName} -Severity 3 -ForceToConsole
                        Write-TempLog "FYI: *sitting on it* means just having the file selected in Windows Explorer. " -source $CmdletName -Severity 3 -ForceToConsole
                        $exitcode = 70003
                        Exit-ScriptLogHandling $exitcode
                    }
                    
                    $iLoopCount++ 
                    if ($iLoopCount -GT $ConfigMaxNumOfBkLogFiles) { $iLoopCount=1 } #prevents having more than $MaxNumOfBkLogFiles copies
                    [string]$FutureLogFullPath = "${LogFileParentFolder}\${logFileNameOnly}.bk" + $iLoopCount + ".zip"
                    Write-TempLog "INFO: Making sure .BK${iLoopCount}.zip does NOT exist for next run." -Source ${CmdletName}
                    Try {
                        If (Test-Path $FutureLogFullPath) {
                            Write-TempLog "INFO: [$FutureLogFullPath] exists already. Must delete" -Source ${CmdletName}
                            Write-TempLog "INFO: Creating a missing .BK#.zip for next run. Needed to overwrite old logs, next time" -Source ${CmdletName}
                            Remove-Item -Path $FutureLogFullPath -ErrorAction stop
                            Write-TempLog "INFO: [$FutureLogFullPath] deleted. We are good for the next run of this script" -Source ${CmdletName}
                        }
                    } catch {
                        If (($Host.Name -eq "ConsoleHost") -and $adtConfig.Toolkit.LogWriteToHost ) { 
                            Try { cmd /c color 4f } Catch { } #Make screen go RED (works in PS1 console, Fails in PowerGUI)
                        }
                        Write-TempLog "ERROR: Unable to delete old [$FutureLogFullPath] file. Check if another process has it open or is `"sitting`" on it" -Source ${CmdletName} -Severity 3
                        Write-TempLog "FYI: *sitting on it* means just having the file selected in Windows Explorer. "
                        $exitcode = 70004
                        Exit-ScriptLogHandling $exitcode
                    }
                    
                } Else {
                    If (($Host.Name -eq "ConsoleHost") -and $adtConfig.Toolkit.LogWriteToHost ) {
                        Try { cmd /c color 4f} Catch { }  #Make screen go RED (works in PS1 console, Fails in PowerGUI)
                    }
                    Write-TempLog "ERROR: Insufficient rights to backup old [$logFileNameOnly] to [${logFileNameOnly}.bk${iLoopCount}.zip]" -Source ${CmdletName} -Severity 3
                    $exitcode = 70005
                    Exit-ScriptLogHandling $exitcode
                }
            }
            
        } else {
            Write-TempLog "INFO: No log file to roll over."  -Source ${CmdletName}
        }
        Start-Sleep -Seconds 3
        If ($DebugLogHandling) {
            Write-TempLog "No issues during Log File Rotation, `$DebugLogHandling = $DebugLogHandling. [$logTempFile] not deleted" -Source ${CmdletName}
        } Else {
            Write-TempLog "No issues during Log File Rotation, deleting Temporary log file [$logTempFile]..." -Source ${CmdletName}
            Start-Sleep -Seconds 2
            Remove-Item -Path $logTempFile -Force -ErrorAction SilentlyContinue  #Comment this line to keep log handling logs
        }
        #TODO
        #In V3, this was needed for some reason or else we can't read the console
        #Note: for V4 we will try to do without this hack
        # $Host.UI.RawUI.BackgroundColor = "Blue"
        # $Host.UI.RawUI.ForegroundColor = "White"
    } #Rotate-Logfiles
Set-Alias -Name Rotate-Logfiles -Value Invoke-LogfileRotation
    

#-----------------------------------------------------------------------------
# MARK: Merge-ToOneLogFile
#-----------------------------------------------------------------------------
Function Merge-ToOneLogFile {
    <#
    .SYNOPSIS
        Merges/Appends logs in $logTempFolder to a single file
        TODO: replace -ContinueOnError with -ErrorAction (Cannot -ErrorAction is a reserved parameter, will need to ask how they do it)
    .DESCRIPTION
        Creates a single new log file from folder of logfiles or an array of logfile paths
        Handles different log file encodings (UTF8, ANSI, etc)
        Output encoding is UTF8
        Merges log files in Chronological order using "Date Last Modified" timestamp
        Add header at top of each: ++ * LogFile: "<Name of log file>"
        Appends PSADT's log file as the last log file
        Appends the Exitcode from PSADT to LAST Line if possible
        Based on PSADT's New-ZipFile while matching parameters (New-ADTZipFile)
        CAVEAT: Sub-folders of $SourceDirectoryPath are ignored
        
    .PARAMETER DestinationArchiveDirectoryPath
        The path to the directory path where the merged log file will be saved.
        
    .PARAMETER DestinationArchiveFileName
        The name of the merged log file
        
    .PARAMETER SourceDirectoryPath
        The path to the directory to be archived, specified as absolute paths.
        CAVEAT: Use -SourceDirectoryPath or -SourceFilePath. Not both! -SourceDirectoryPath has precedence.
           
    .PARAMETER RemoveSourceAfterArchiving
        Remove the source path after successfully archiving the content. Default is: $false.
        
    .PARAMETER Force
        Specifies whether an existing zip file should be overwritten. (replaces -OverWriteArchive)
        
    .PARAMETER ErrorAction
        Continue if an error is encountered. Default: $true.
        
    .PARAMETER ExitCode
        Used to insert the ExitCode of the script in the last line of the merged log file
        
    .EXAMPLE
        Merge-ToOneLogFile -DestinationArchiveDirectoryPath $LogPath -DestinationArchiveFileName $DestinationArchiveFileName -SourceDirectory $logTempFolder -RemoveSourceAfterArchiving -ExitCode $ExitCode
    .EXAMPLE
        Merge-ToOneLogFile -DestinationArchiveDirectoryPath $LogPath -DestinationArchiveFileName "previouspkg_v1r1.log" -SourceFilePath $ArrayOfFilePaths
        
    .NOTES
        We use this in 2 scenarios:
        -At the end of a package Run (when the script ends normally)
        -At the beginning of a package Run (to cleanup the log files from a *previous* package Run that ended AB-normally)
        CAVEAT: if one of the source log files has mixed encodings, this will cause 0x00 chars to get in the final log file

    .LINK
        https://psappdeploytoolkit.com
    #>

    [CmdletBinding(DefaultParameterSetName = 'CreateFromDirectory')]
    Param (
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateNotNullorEmpty()]
        [string]$DestinationArchiveDirectoryPath,
        
        [Parameter(Mandatory=$true,Position=1)]
        [ValidateNotNullorEmpty()]
        [string]$DestinationArchiveFileName,
        
        [Parameter(Mandatory=$true,Position=2,ParameterSetName='CreateFromDirectory')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType 'Container' })]
        [string[]]$SourceDirectoryPath,
            
        [Parameter(Mandatory=$false,Position=3)]
        [ValidateNotNullorEmpty()]
        [switch]$RemoveSourceAfterArchiving = $false,
        
        [Parameter(Mandatory=$false,Position=4)]
        [ValidateNotNullorEmpty()]
        [switch]$Force = $false,

        [Parameter(Mandatory=$false,Position=5)]
        [ValidateNotNullorEmpty()]
        [boolean]$ContinueOnError = $true,

        [Parameter(Mandatory=$false)]
        [ValidateNotNullorEmpty()]
        [int32]$ExitCode
    )

    begin {
        ## Get the name of this function and write header
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
		# Remove invalid characters from the supplied filename. [todo]
    }
    
    Process {
        Try {
            If ($SourceDirectoryPath -eq $LogPath) { 
                Write-templog "ERROR: You are about to Merge *ALL* log files in [$LogPath] and they would then be deleted. Aborted to prevent all log files from being trashed." -Source ${CmdletName} -Severity 3
                Throw "Merging *ALL* log files in [$LogPath] aborted to prevent all log files from being trashed."
            }
            If ( -not ([System.IO.Directory]::Exists($SourceDirectoryPath))) {
                Write-templog "Log folder [$SourceDirectoryPath] does NOT exist. Nothing to do." -Source ${CmdletName}
                return
            }
            
            ## Get the full destination path where the archive will be stored
            [string]$DestinationPath = Join-Path -Path $DestinationArchiveDirectoryPath -ChildPath $DestinationArchiveFileName -ErrorAction 'Stop'
            Write-templog -Message "Creating a Merged log file with the requested content at destination path [$DestinationPath]." -Source ${CmdletName}

            ## If the destination archive already exists, delete it if the -force option was selected.
            If (($Force) -and ([System.IO.File]::Exists($DestinationPath))) {
                Write-templog -Message "An archive at the destination path already exists, deleting file [$DestinationPath]." -Source ${CmdletName}
                $null = Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction 'Stop'
            } ElseIf ( [System.IO.File]::Exists($DestinationPath)) {
                Write-templog -Message "[$DestinationPath] already exists. Rotating Logfiles." -Source ${CmdletName}
                Rotate-Logfiles -LogFileNameToRotate $DestinationPath -LogFileParentFolder $LogPath
            } 

            ## Create the archive file
            If ($PSCmdlet.ParameterSetName -eq 'CreateFromDirectory') {
                ## Create the MERGED file from a source directory
                
                $OutPutFileEncoding = "UTF8"	#Output encoding is UTF8
                $Utf8NoBomEncoding	= New-Object System.Text.UTF8Encoding($False)
                $Utf8Encoding 		= New-Object System.Text.UTF8Encoding($true)
                
                If (([System.IO.Directory]::Exists($SourceDirectoryPath)) -and ( $(Get-ChildItem $SourceDirectoryPath).Count -gt 0 )) {
                    [String]$ListOfLogs = Get-ChildItem $SourceDirectoryPath | Sort-Object -Property LastWriteTime | Select-Object LastWriteTime,length,name | Format-Table -AutoSize | Out-string
                    [String]$ListOfLogs = "The following files will be Merged to one .Log file:`r`n" + $ListOfLogs +"`r"
                    $ListOfLogs | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                    
                    #Here we append all the log files into this script's log file, one after another in Chronological order (Oldest first)
                    ForEach ($file in (Get-ChildItem $SourceDirectoryPath | Sort-Object -Property LastWriteTime)) {
                        Write-templog "Collecting log file [$($file.Name)] to [$DestinationPath]..." -Source ${CmdletName}
                        "+*+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*+" | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                        "+* LogFile: `"$($file.FullName)`"" | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                        "+*+++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++++*+" | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                        " " | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue # b/c `n didn't work
                        Try {
                            [System.Collections.IEnumerable]$ContentIEnum = Get-Content $file.FullName -ErrorAction Stop | Out-String
                        } Catch {
                            [string]$ErrorMessage = "$($_.Exception.Message) $($_.ScriptStackTrace) $($_.Exception.InnerException)"
                            "ERROR: Unable to collect [$($file.FullName)]: [$ErrorMessage]" | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                            Start-sleep -Seconds 11						#TODO: Why do we do it this way?
                            #$RemoveSourceAfterArchiving = $false
                        }
                        if ( ( $null -ne $ContentIEnum ) -or ( $ContentIEnum.Length -lt 1) ) {
                            [System.IO.File]::AppendAllText($DestinationPath, $ContentIEnum, $Utf8Encoding)				
                        } else {
        #					Write-Host "[ $($file.name) is $($content.Length) bytes ]"
                            [System.IO.File]::AppendAllText($DestinationPath, "[ $($file.name) is $($content.Length) bytes ]", $Utf8Encoding)
                        }
                        "`r`nEND OF LOG: `"$($file.FullName)`" " | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                        " `r`n `r`n " | Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue #2+1 blank lines with a space
                        Start-Sleep -Milliseconds 80 #just in case
                    }
                    
                    
                    
                    If (($null -ne $ExitCode) -or ($ExitCode -ne "")) {
                        #Use $exitcode param and make it the last line in the AppendedLogFile
                        "EXITCODE=($ExitCode) - $(Get-Date -format "dd/MM/yyyy HH:mm:ss").50"| Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                    } else {
                        "EXITCODE=( ???? ) - $(Get-Date -format "dd/MM/yyyy HH:mm:ss").50"| Out-File $DestinationPath -Append -Encoding $OutPutFileEncoding -ErrorAction SilentlyContinue
                    }
                } Else {
                    Write-templog "Log folder [$SourceDirectoryPath] is EMPTY. Nothing to do." -Source ${CmdletName}
                }


                # If option was selected, recursively delete the source directory after successfully archiving the contents
                If ($RemoveSourceAfterArchiving) {
                    Try {
                        If ( ([System.IO.Directory]::Exists($SourceDirectoryPath)) -and ([System.IO.File]::Exists($DestinationPath) ) ) { 
                            Write-templog "Merged file found [$DestinationPath]" -Source ${CmdletName}
                            Write-templog -Message "Deleting the source directory [$SourceDirectoryPath] as contents have been successfully merged." -Source ${CmdletName}
                            Remove-Item -LiteralPath $SourceDirectoryPath -Recurse -Force -ErrorAction 'Stop' | Out-Null
                        } Else {
                            Write-templog "`$SourceDirectoryPath [$SourceDirectoryPath] or `$DestinationPath [$DestinationPath] do not exist." -Source ${CmdletName} -Severity 3
                            Write-templog "An error occurred while appending the log files: $($_.Exception.Message)" -Source ${CmdletName}
                            If (-not $ContinueOnError) {
                                Throw "`$SourceDirectoryPath [$SourceDirectoryPath] or `$DestinationPath [$DestinationPath] do not exist."
                            }
                        }
                    } Catch {
                        [String]$ResolveErrorString = "$($_.Exception.Message) $($_.ScriptStackTrace) $($_.Exception.InnerException)"
                        Write-templog -Message "Failed to recursively delete the source directory [$SourceDirectoryPath]. `r`n[$ResolveErrorString]" -Severity 2 -Source ${CmdletName}
                    }
                }
            }

        } catch {
            [String]$ResolveErrorString = "$($_.Exception.Message) $($_.ScriptStackTrace) $($_.Exception.InnerException)"
            Write-templog -Message "Failed to *Merge* the requested file(s). `r`n[$ResolveErrorString]" -Severity 3 -Source ${CmdletName}
            If (-not $ContinueOnError) {
                Throw "Failed to *Merge* the requested file(s): $($_.Exception.Message)"
            }
        }	

        Write-TempLog "No issues during Log File Merging, deleting Temporary log file [$logTempFile]" -Source ${CmdletName}
        Start-Sleep -Seconds 3
        If ($DebugLogHandling) {
            Write-TempLog "`$DebugLogHandling = $DebugLogHandling. [$logTempFile] not deleted" -Source ${CmdletName}
        } Else {
            Remove-Item -Path $logTempFile -Force -ErrorAction SilentlyContinue  #Comment this line to keep log handling logs
        }
    } 

    end {
        #Write-FunctionHeaderOrFooter -CmdletName ${CmdletName} -Footer
        Write-TempLog "[${CmdletName}] is done" -Source ${CmdletName} -Severity 0
    }
} #Merge-ToOneLogFile


#-----------------------------------------------------------------------------
# MARK: Merge-ToOneZipFile
#-----------------------------------------------------------------------------
Function Merge-ToOneZipFile {
    <#
    .SYNOPSIS
    Create a new zip archive or add content to an existing archive.
    TODO: replace -ContinueOnError with -ErrorAction
    .DESCRIPTION
    Create a new zip archive or add content to an existing archive by using the Shell object .CopyHere method.
    .PARAMETER DestinationArchiveDirectoryPath
    The path to the directory path where the zip archive will be saved.
    .PARAMETER DestinationArchiveFileName
    The name of the zip archive.

    .PARAMETER SourceDirectoryPath
    The path to the directory to be archived, specified as absolute paths.

    .PARAMETER RemoveSourceAfterArchiving
    Remove the source path after successfully archiving the content. Default is: $false.

    .PARAMETER OverWriteArchive
    Overwrite the destination archive path if it already exists. Default is: $false.

    .PARAMETER ContinueOnError
    Continue if an error is encountered. Default: $true.

    .INPUTS
    None
    You cannot pipe objects to this function.

    .OUTPUTS
    None
    This function does not generate any output.

    .EXAMPLE
    Merge-ToOneZipFile -DestinationArchiveDirectoryPath 'E:\Testing' -DestinationArchiveFileName 'TestingLogs.zip' -SourceDirectory 'E:\Testing\Logs'

    .NOTES
    #>

    [CmdletBinding(DefaultParameterSetName = 'CreateFromDirectory')]
    Param (
        [Parameter(Mandatory=$true,Position=0)]
        [ValidateNotNullorEmpty()]
        [string]$DestinationArchiveDirectoryPath,
        
        [Parameter(Mandatory=$true,Position=1)]
        [ValidateNotNullorEmpty()]
        [string]$DestinationArchiveFileName,
        
        [Parameter(Mandatory=$true,Position=2,ParameterSetName='CreateFromDirectory')]
        [ValidateScript({ Test-Path -LiteralPath $_ -PathType 'Container' })]
        [string[]]$SourceDirectoryPath,
        
        [Parameter(Mandatory=$false,Position=3)]
        [ValidateNotNullorEmpty()]
        [switch]$RemoveSourceAfterArchiving = $false,
        
        [Parameter(Mandatory=$false,Position=4)]
        [ValidateNotNullorEmpty()]
        [switch]$Force = $false,

        [Parameter(Mandatory=$false,Position=5)]
        [ValidateNotNullorEmpty()]
        [boolean]$ContinueOnError = $true

    )

    begin {
        ## Get the name of this function and write header
        [string]${CmdletName} = $PSCmdlet.MyInvocation.MyCommand.Name
		# Remove invalid characters from the supplied filename. [TODO]
    }
    
    Process {
        Try {
            If ($SourceDirectoryPath -eq $LogPath) {
                Write-templog "ERROR: You are about to ZIP *ALL* log files in [$LogPath] and they would then be deleted. Aborted to prevent all log files from being trashed." -Source ${CmdletName} -Severity 3
                Throw "Zipping *ALL* log files in [$LogPath] aborted to prevent all log files from being trashed."
            }
            If ( -not ([System.IO.Directory]::Exists($SourceDirectoryPath))) {
                Write-templog "Log folder [$SourceDirectoryPath] does NOT exist. Nothing to do." -Source ${CmdletName}
                return
            }
            
            ## Remove invalid characters from the supplied filename
            $DestinationArchiveFileName = Remove-InvalidFileNameChars -Name $DestinationArchiveFileName
            If ($DestinationArchiveFileName.length -eq 0) {
                Throw 'Invalid filename characters replacement resulted into an empty string.'
            }
            ## Get the full destination path where the archive will be stored
            [string]$DestinationPath = Join-Path -Path $DestinationArchiveDirectoryPath -ChildPath $DestinationArchiveFileName -ErrorAction 'Stop'
            Write-templog -Message "Creating a zip archive with the requested content at destination path [$DestinationPath]." -Source ${CmdletName}

            ## If the destination archive already exists, delete it if the -force option was selected.
            If (($Force) -and ([System.IO.Directory]::Exists($DestinationPath))) {
                Write-templog -Message "An archive at the destination path already exists, deleting file [$DestinationPath]." -Source ${CmdletName}
                $null = Remove-Item -LiteralPath $DestinationPath -Force -ErrorAction 'Stop'
            } ElseIf ( [System.IO.File]::Exists($DestinationPath)) {
                Write-templog -Message "[$DestinationPath] already exists. Rotating Logfiles." -Source ${CmdletName}
                Rotate-Logfiles -LogFileNameToRotate $DestinationPath -LogFileParentFolder $LogPath
            } 

            ## Create the archive file
            ## If archive file does not exist, then create a zero-byte zip archive
            If (-not ([System.IO.File]::Exists($DestinationPath))) {
                ## Create a zero-byte file
                Write-templog -Message "Creating a zero-byte file [$DestinationPath]." -Source ${CmdletName}
                $null = New-Item -Path $DestinationArchiveDirectoryPath -Name $DestinationArchiveFileName -ItemType 'File' -Force -ErrorAction 'Stop'

                ## Write the file header for a zip file to the zero-byte file
                [Byte[]]$ZipArchiveByteHeader = 80, 75, 5, 6, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0
                [IO.FileStream]$FileStream = New-Object -TypeName 'System.IO.FileStream' -ArgumentList ($DestinationPath, ([IO.FileMode]::Create))
                [IO.BinaryWriter]$BinaryWriter = New-Object -TypeName 'System.IO.BinaryWriter' -ArgumentList ($FileStream)
                Write-templog -Message "Write the file header for a zip archive to the zero-byte file [$DestinationPath]." -Source ${CmdletName}
                $null = $BinaryWriter.Write($ZipArchiveByteHeader)
                $BinaryWriter.Close()
                $FileStream.Close()
            }

            ## Create a Shell object
            [__ComObject]$ShellApp = New-Object -ComObject 'Shell.Application' -ErrorAction 'Stop'
            ## Create an object representing the archive file
            [__ComObject]$Archive = $ShellApp.NameSpace($DestinationPath)

            ## Create the archive file
            If ($PSCmdlet.ParameterSetName -eq 'CreateFromDirectory') {
                ## Create the archive file from a source directory
                ForEach ($Directory in $SourceDirectoryPath) {
                    Try {
                        #  Create an object representing the source directory
                        [__ComObject]$CreateFromDirectory = $ShellApp.NameSpace($Directory)
                        #  Copy all of the files and folders from the source directory to the archive
                        $null = $Archive.CopyHere($CreateFromDirectory.Items())
                        #  Wait for archive operation to complete. Archive file count property returns 0 if archive operation is in progress.
                        Write-templog -Message "Compressing [$($CreateFromDirectory.Count)] file(s) in source directory [$Directory] to destination path [$DestinationPath]..." -Source ${CmdletName}
                        Do {
                            Start-Sleep -Milliseconds 250
                        } While ($Archive.Items().Count -eq 0)
                    } Finally {
                        #  Release the ComObject representing the source directory
                        $null = [Runtime.Interopservices.Marshal]::ReleaseComObject($CreateFromDirectory)
                    }


                    # If option was selected, recursively delete the source directory after successfully archiving the contents
                    If ($RemoveSourceAfterArchiving) {
                        Try {
                            Write-templog -Message "Recursively deleting the source directory [$Directory] as contents have been successfully archived." -Source ${CmdletName}
                            $null = Remove-Item -LiteralPath $Directory -Recurse -Force -ErrorAction 'Stop'
                        } Catch {
                	        [String]$ResolveErrorString = "$($_.Exception.Message) $($_.ScriptStackTrace) $($_.Exception.InnerException)"
                            Write-templog -Message "Failed to recursively delete the source directory [$Directory]. `r`n[ResolveErrorString]" -Severity 2 -Source ${CmdletName}
                        }
                    }
                }
            }

            ## If the archive was created in session 0 or by an Admin, then it may only be readable by elevated users.
            # Apply the parent folder's permissions to the archive file to fix the problem.
            Write-templog -Message "If the archive was created in session 0 or by an Admin, then it may only be readable by elevated users. Apply permissions from parent folder [$DestinationArchiveDirectoryPath] to file [$DestinationPath]." -Source ${CmdletName}
            try {
                [Security.AccessControl.DirectorySecurity]$DestinationArchiveDirectoryPathAcl = Get-Acl -Path $DestinationArchiveDirectoryPath -ErrorAction 'Stop'
                Set-Acl -Path $DestinationPath -AclObject $DestinationArchiveDirectoryPathAcl -ErrorAction 'Stop'
            } catch {
                [String]$ResolveErrorString = "$($_.Exception.Message) $($_.ScriptStackTrace) $($_.Exception.InnerException)"
                Write-templog -Message "Failed to apply parent folder's [$DestinationArchiveDirectoryPath] permissions to file [$DestinationPath]. `r`n[ResolveErrorString]" -Severity 3 -Source ${CmdletName}
            }
        } catch {
        	[String]$ResolveErrorString = "$($_.Exception.Message) $($_.ScriptStackTrace) $($_.Exception.InnerException)"
            Write-templog -Message "Failed to *archive* the requested file(s). `r`n[$ResolveErrorString]" -Severity 3 -Source ${CmdletName}
            If (-not $ContinueOnError) {
                Throw "Failed to *archive* the requested file(s): $($_.Exception.Message)"
            }
        }
        Finally {
            ## Release the ComObject representing the archive
            If ($Archive) {
                $null = [Runtime.Interopservices.Marshal]::ReleaseComObject($Archive)
            }
        }
    }
    end {
        #Write-FunctionHeaderOrFooter -CmdletName ${CmdletName} -Footer
    }
}


#-----------------------------------------------------------------------------
# MARK: Write-TempLog
#-----------------------------------------------------------------------------
Function Write-TempLog {
    <#
    .SYNOPSIS
        Writes output to the console and to a temporary log file simultaneously
    .DESCRIPTION
        This functions outputs text to the console ($adtConfig.Toolkit.LogWriteToHost permitting) and to a Temporary log file in %TEMP%.
        It is meant to be used only by functions in this module.
    .EXAMPLE
        Write-TempLog -Message "This is a custom message..." -Severity 0
    .EXAMPLE
        Write-TempLog -Message "This is a custom message..." -Severity 3
    .EXAMPLE
        dir C:\Temp | Write-TempLog
    .PARAMETER Message
        What goes to the Templog (and screen if needed)
    .PARAMETER Severity
        Controls the color of the text in the Console (same as PSADT v4)
        0 = Green  for good / positive thing
        1 = Regular for info
        2 = Yellow for warnings
        3 = Red for Errors
        4 = grey for low importance / debug (not in PSADT and default for MergeNRollLogs module)
    .PARAMETER Source
        Shows to Console even if $DebugLogHandling is $False
    .PARAMETER ForceToConsole
        Shows to Console even if $DebugLogHandling is $False
    .NOTES
        $logTempFile is defined in the SCRIPT BODY section below 
    .LINK
        Http://psappdeploytoolkit.codeplex.com
    #>
    Param(
        [Parameter(Mandatory = $true,ValueFromPipeline=$True,ValueFromPipelinebyPropertyName=$True)]
        [array]$Message,
        [Int16]$Severity = 4,
        [String]$Source,
        [Switch]$ForceToConsole = $False
    )
    Process {
        Try {
            [string]$LogFileDirectory = [System.IO.Path]::GetDirectoryName($logTempFile)
            [String]$LogFileName	= [System.IO.Path]::GetFileName($logTempFile)
            [String]$PreLogPath = Join-Path -Path $LogFileDirectory -ChildPath $LogFileName
            
            #format the line
            [String]$lTextLogLine = "[$(Get-Date)][$Source]$Message"
            If ($DebugLogHandling -or $ForceToConsole) {
                #  Only output using color options if running in a host which supports colors.
                If ($Host.UI.RawUI.ForegroundColor) {
                    Switch ($Severity) {
                        4 {
                            Write-Host -Object $lTextLogLine -ForegroundColor 'DarkGray' -BackgroundColor 'Black'
                        }
                        3 {
                            Write-Host -Object $lTextLogLine -ForegroundColor 'Red' -BackgroundColor 'Black'
                        }
                        2 {
                            Write-Host -Object $lTextLogLine -ForegroundColor 'Yellow' -BackgroundColor 'Black'
                        }
                        1 {
                            Write-Host -Object $lTextLogLine
                        }
                        0 {
                            Write-Host -Object $lTextLogLine -ForegroundColor 'Green' -BackgroundColor 'Black'
                        }
                    }
                } Else {
                    Write-Output -InputObject ($lTextLogLine)
                }
            }

            If ( Test-Path $PreLogPath ){
                "[$(Get-Date)][$Source]$Message" | Out-File -FilePath $PreLogPath -Append -NoClobber -Force -Encoding 'UTF8' -ErrorAction 'Stop'
    #			$Message | Out-File -FilePath $LogPath -Append -Force -Encoding 'UTF8' -ErrorAction 'Stop'
            } Else {
                #File does not exist. Create all folders and the file. (NOTE: Out-File cannot create folders but New-Item can.
                $null = New-Item -Path $PreLogPath -ItemType File -Force #-Value "*** Installation Starting... $(get-date) ***" 
                "[$(Get-Date)][$Source]$Message" | Out-File -FilePath $PreLogPath -Append -NoClobber -Force -Encoding 'UTF8' -ErrorAction 'Stop'
            }
        } Catch {
            $PreExitCode = $_.Exception.HResult
            Write-Error -Message "ERROR in Write-TempLog function: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage) `n$($_.Exception.InnerException) `n$PreExitCode" -ErrorAction 'Continue'
            Start-Sleep -Seconds 10
            ## Exit the script, returning the exit code to SCCM/Intune
            If (Test-Path -LiteralPath 'variable:HostInvocation') {
                $script:ExitCode = $PreExitCode; Exit
            } Else {
                Exit $PreExitCode
            }
        }
    }
} #Write-TempLog
    

#-----------------------------------------------------------------------------
# MARK: Exit-ScriptLogHandling
#-----------------------------------------------------------------------------
Function Exit-ScriptLogHandling {
    <#
    .SYNOPSIS
        Exits the script during log handling, copies the $logTempFile to %logs%, and pass an exit code to the parent process.
    .DESCRIPTION
        For use by the Log handling functions before log handling functions are defined.
        Only used when things go bad in this module's functions.
    .PARAMETER ExitCode
        The exitcode to be passed from the script to the parent process, e.g. SCCM/Intune
    .EXAMPLE
        Exit-ScriptLogHandling -ExitCode 0
    .EXAMPLE
        Exit-ScriptLogHandling -ExitCode 1618
    .NOTES
    #>
        [CmdletBinding()]
        Param (
            [Parameter(Mandatory=$false)]
            [ValidateNotNullorEmpty()]
            [int32]$ExitCode = 0
        )
        Write-TempLog "$installName $($adtSession.DeploymentType) failed its log handling with Exitcode [$exitcode]." -Source ${CmdletName}
        Start-Sleep -Second 10
        
        Copy-Item -Path $logTempFile -Destination "$envLogs\Install\${installName}_LOGGING.log" -ErrorAction SilentlyContinue -Force
        # Must exit script this way because Exit-Script() assumes log files exists and are OK to use. Could causes a loop and endless log files
        #WARNING: due to a Dot Sourcing bug, the following will exit this function (instead of the script) and return control to what called it.
    #	$host.SetShouldExit($exitcode)
    #	Exit
        #TODO: does this Exit gracefully?
        Throw "Log handling failed with ExitCode [$exitcode]" # You'd think this would be caught in the Try/Catch of the front script. Um, no. It kills the script promptly.
    } #Exit-ScriptLogHandling
    

#-----------------------------------------------------------------------------
# MARK: Invoke-MergeNRollLogs
#-----------------------------------------------------------------------------
Function Invoke-MergeNRollLogs {
    <#
    .SYNOPSIS
        This is the main function to process log files using our functions as per settings in the Config.psd1 file
    .DESCRIPTION
        We call this function before and after a PSADT session. NEVER DURING AN OPEN SESSION
        1 - We call this function AFTER the PSADT module it loaded but BEFORE the session is opened.
            This is to clean-up the log files of a previous session of the same package.
            We Set GAC vars $envLogs, $envAdmutils
            we also roll the log files AFTER the clean up on start but BEFORE we open the session.
        2 - We call this function AFTER the PSADT session is closed
            we do not roll the log files after PSADT session is closed.

    .EXAMPLE
        Invoke-MergeNRollLogs -PreOpenSession
        We call this function with -PreOpenSession in the Front Script AFTER the PSADT module it loaded but BEFORE the session is opened.
        0- We read \Config\Config.psd1
        1- We set GAC vars $envLogs, $envAdmutils because they are referenced in config.psd1
        2- We clean UP the log files of a previous run of the same package.
        3- We roll the log files AFTER to make sure we don't overwrite existing log files BEFORE we open the PSADT session.
    .EXAMPLE
        Invoke-MergeNRollLogs
        We call this function AFTER the PSADT session is closed in the Front Script's `finally{ }` Section before the ExitCode is returned to Intuen or SCCM
        NOTE: We do not roll the log files after PSADT session is closed.
    .PARAMETER PreOpenSession
        Use to tell this function that we are running BEFORE the PSADT session is opened.
        This triggers different sections of code and even changes some of the logging messages
    .NOTES
        The $ADTConfig defined here SHOULD be visible to the private functions that are called but not to the rest of PSADT
        TODO: Does Get-ADTConfig handle Environment Vars directly (e.g. $Env:TEMP) is used in Condfig.psd1?

        $adtSession.LogTempFolder is the path to the temporary subfolder. 
        $LogPath is where the merged/zipped log files go when we are done.
        Log file for all this is %temp%\$($adtSession.InstallName)_LogHandling_<Random>.log
    .LINK
        Http://psappdeploytoolkit.codeplex.com
    #>
    [CmdletBinding()]
    Param(
        [Parameter(Mandatory = $false)]
        [switch]$PreOpenSession
    )
    Try {
        ## Get the name of this function to set the -source paremeter for Write-TempLog
        [string]$CmdletName = $PSCmdlet.MyInvocation.MyCommand.Name
        If ($PreOpenSession) {
            [string]$CmdletName = "$($PSCmdlet.MyInvocation.MyCommand.Name)_PreOpenSession"
        }

        If ($PreOpenSession -eq $True) {
            #Using PS-native Import-PowerShellDataFile to read the "Front-version" of Config.psd1
            #This version of $PreAdtConfig will be discarded when loading this Module is done
            $AdtConfig = Import-PowerShellDataFile "$($adtSession.FrontScriptDirectory)\config\Config.psd1"
        } Else {
            #After the PSADT session is closed, we can use PSADT's Get-ADTConfig
            $AdtConfig = Get-ADTConfig
        }
        
        #Set as per Config.psd1
        [Boolean]$DebugLogHandling = $($AdtConfig.MergeNRollLogs.LogHandlingDebug)
    
        #Determine if we keep the TempLogFile after handling log file is done
        If ($DebugLogHandling) {
            # $true = keep the Temporary log file (Used for DEV)
            # Log file is created in %temp%
            Write-Warning "[$CmdletName] `$DebugLogHandling defined as [$DebugLogHandling]"
        }
    
        #Create a separate log file for log handling
        #CAVEAT: can't use Write-TempLog until $logTempFile is fully defined below
        [string]$logTempFile = [System.IO.Path]::GetTempFileName()
        Remove-Item -Path $logTempFile -Force -ErrorAction SilentlyContinue  #Remove gratuitously created .TMP file by line above
        [string]$logTempFileName = [System.IO.Path]::GetFileNameWithoutExtension($logTempFile)
        [string]$logTempFileName = $logTempFileName.Replace('tmp',"$($adtSession.InstallName)_LogHandling_")
        [string]$logTempFile = Join-path -Path $Env:temp -ChildPath "${logTempFileName}.log"
        #$logTempFile is defined, NOW we can call Write-TempLog
        If ($DebugLogHandling) { Write-Warning "[$CmdletName] LogHandling lof file is `$logTempFile = [$logTempFile]"  }
        Remove-Variable logTempFileName -ErrorAction SilentlyContinue
    
        #Log Config.psd1 Setting as they are
        Write-TempLog "--------------------------------------------"                -source $CmdletName
        Write-TempLog "-PreOpenSession   [$PreOpenSession]"                         -source $CmdletName -Severity 0
        Write-TempLog "************ Log of log handling Started *********************" -source $CmdletName
        Write-TempLog "PSADT settings as found in Config\Config.psd1"              -source $CmdletName
        Write-TempLog "CompressLogs      [$($AdtConfig.Toolkit.CompressLogs)]"     -source $CmdletName
        Write-TempLog "LogPath           [$($AdtConfig.Toolkit.LogPath)]"          -source $CmdletName
        Write-TempLog "LogToSubfolder    [$($AdtConfig.Toolkit.LogToSubfolder)]"   -source $CmdletName
        Write-TempLog "LogStyle          [$($AdtConfig.Toolkit.LogStyle)]"         -source $CmdletName
        If (-not $PreOpenSession) {
        Write-TempLog "LogTempFolder     [$($adtSession.LogTempFolder)]  (Defaults to `$envTemp\`$adtSession.InstallName)" -source $CmdletName
        }   #otherwise it doesn't exist yet, b/c session has not happened yet
        Write-TempLog "--------------------------------------------"                      -source $CmdletName
        Write-TempLog "MergeNRollLogs settings as found in Config\Config.psd1"            -source $CmdletName
        Write-TempLog "LogHandlingDebug  [$($AdtConfig.MergeNRollLogs.LogHandlingDebug)]" -source $CmdletName
        Write-TempLog "LogsAreCompressed [$($AdtConfig.MergeNRollLogs.LogsAreCompressed)]" -source $CmdletName
        Write-TempLog "LogCompressFormat [$($AdtConfig.MergeNRollLogs.LogCompressFormat)]" -source $CmdletName
        Write-TempLog "RotateLogFiles    [$($AdtConfig.MergeNRollLogs.RotateLogFiles)]"    -source $CmdletName


    
        # $LogPath is where the merged/compressed log files go when we are done.
        [String]$LogPath = $AdtConfig.Toolkit.LogPath
        $AdtConfig.Toolkit.LogPath = $LogPath = Invoke-expression "`"$LogPath`"" #Force Expand Environment Vars b/c Test-path will not do it! #TODO: use Mitch method
Write-host "[$CmdletName] `$AdtConfig.Toolkit.LogPath [$($AdtConfig.Toolkit.LogPath)]" -ForegroundColor Magenta #DEV ONLY *****************************************************
Write-host "[$CmdletName] `$LogPath [$LogPath]" -ForegroundColor Magenta #DEV ONLY *****************************************************
    
        #Set $installName, $LogExtension, $DestinationArchiveFileName, $logTempFolder
        [String]$installName    = $adtSession.InstallName
        [String]$LogExtension   = $AdtConfig.MergeNRollLogs.LogCompressFormat #either .Log or .Zip
        [string]$DestinationArchiveFileName = $adtSession.Logname
        [String]$logTempFolder = $adtSession.LogTempFolder = Join-Path -Path $AdtConfig.Toolkit.LogPath -ChildPath $adtSession.InstallName #So that all log files are in AdtConfig.Toolkit.LogPath
    
        # Another Pretty block of $adtSession properties
        Write-TempLog "`$adtSession.$LogTempFolder [$($adtSession.LogTempFolder)]  (folder holding logs that we want to merge (Deleted after MERGED/ZIPPED))" -source $CmdletName
        Write-TempLog "`$AdtConfig.Toolkit.LogPath [$($AdtConfig.Toolkit.LogPath)] (Destination folder for MERGED/ZIPPED logs)" -source $CmdletName
        Write-TempLog "-------------------------------------"                        -source $CmdletName
        Write-TempLog "`$adtSession.Logname is [$($adtSession.Logname)]            (set in Front Script) and is a ReadOnly property once PSADT Uses it" -source $CmdletName
        Write-TempLog "`$DestinationArchiveFileName = [$DestinationArchiveFileName] (Name of the MERGED/ZIPPED Log file)" -source $CmdletName
    
    
        #Prevent OUR compressing/Merging from running if PSADT's CompressLogs is enabled.
        If ($AdtConfig.Toolkit.CompressLogs) {
            Write-TempLog "ERROR: Native PSADT Toolkit.CompressLogs setting in Config.psd1 is set to `$true" -source $CmdletName -Severity 3 -ForceToConsole
            Write-TempLog "This setting is not compatible this [$ModuleName] module" -source $CmdletName -Severity 3 -ForceToConsole
            Write-TempLog "terminating the import of this [$ModuleName] module" -source $CmdletName -Severity 3 -ForceToConsole
            Start-Sleep -Seconds 10
            Throw "Toolkit.CompressLogs setting in Config.psd1 in not compatible. Terminating import of module...(but not stop script!?!?)"
    
        } ElseIf ($AdtConfig.MergeNRollLogs.LogsAreCompressed) {
        
            #Clean up log files leftover from a previous run
            If (Test-Path -Path $adtSession.LogTempFolder -ErrorAction SilentlyContinue ) { 
                If ($AdtConfig.Toolkit.LogWriteToHost) {
                    If ($PreOpenSession) {
                        Write-TempLog "Found a previous run's log files in [$($adtSession.LogTempFolder)]..." -source $CmdletName -Severity 2 -ForceToConsole
                    } Else {
                        Write-TempLog "Merging log files in [$($adtSession.LogTempFolder)]..." -source $CmdletName -Severity 2 -ForceToConsole
                    }
                }

                #Prevent entire LogPath folder from being merged (Should be imposible but just in case)
                If ($adtSession.LogTempFolder -eq $AdtConfig.Toolkit.LogPath ) { 
                        # $adtSession.LogTempFolder cannot be $AdtConfig.Toolkit.LogPath (aka %logs%\install\)
                        Write-TempLog "But [$($adtSession.LogTempFolder)] is not a valid. It cannot be [$($AdtConfig.Toolkit.LogPath)]. Not Compressing or Merging log files." -source $CmdletName -Severity 3 -ForceToConsole
                        Write-TempLog "IOW: The Temporary logs folder cannot be the destination folder as well." -source $CmdletName -Severity 3 -ForceToConsole
                        Start-sleep -Seconds 7 # so that the packager can read it
                        #$exitcode = 70002      
                        #Exit-ScriptLogHandling $exitcode #not needed since we are doing NOTHING
                } Else {
                    If ($AdtConfig.Toolkit.LogWriteToHost -and ($PreOpenSession -eq $True)) { Write-TempLog "Cleaning up Log files..." -source $CmdletName -Severity 2 -ForceToConsole}
    
                    If ($AdtConfig.MergeNRollLogs.LogCompressFormat -eq '.Zip') {
                        [string]$DestinationArchiveFileName = $adtSession.InstallName + '.Zip'
                        Merge-ToOneZipFile -DestinationArchiveDirectoryPath $LogPath -DestinationArchiveFileName $DestinationArchiveFileName -SourceDirectory $adtSession.LogTempFolder -RemoveSourceAfterArchiving
                    } Elseif ($AdtConfig.MergeNRollLogs.LogCompressFormat -eq '.Log') {
                        [string]$DestinationArchiveFileName = $adtSession.InstallName + '.Log'
                        If ($PreOpenSession -eq $True) {
                            #NOTE: Do NOT use -ExitCode $ExitCode when cleaning up from a failed install or remove. 
                            #We do not have this information when we are cleaning up log files before opening a PSADT Session
                            Merge-ToOneLogFile -DestinationArchiveDirectoryPath $LogPath -DestinationArchiveFileName $DestinationArchiveFileName -SourceDirectory $adtSession.LogTempFolder -RemoveSourceAfterArchiving
                        } Else {
                            $ExitCode = $adtSession.GetExitCode() 
                            Merge-ToOneLogFile -DestinationArchiveDirectoryPath $LogPath -DestinationArchiveFileName $DestinationArchiveFileName -SourceDirectory $adtSession.LogTempFolder -RemoveSourceAfterArchiving -ExitCode $ExitCode
                        }
                    } Else {
                        Write-TempLog "`$AdtConfig.MergeNRollLogs.LogCompressFormat setting in Config.psd1 is not supported. Exiting..." -source $CmdletName -Severity 3 -ForceToConsole
                        Start-sleep -Seconds 5
                        Throw "`$AdtConfig.MergeNRollLogs.LogCompressFormat setting in Config.psd1 is not supported. Exiting..."
                    }
                    If ($AdtConfig.Toolkit.LogWriteToHost -and ($PreOpenSession -eq $True)) { Write-TempLog "Cleaning up is done." -source $CmdletName -Severity 2 -ForceToConsole }
                }
            } else { #Test-Path -Path $adtSession.LogTempFolder -eq False. IOW: does not exist
                If ($PreOpenSession -eq $True) {
                    Write-TempLog "Temporary log folder [$($adtSession.LogTempFolder)] does not exist. Nothing to Merge or Compress." -source $CmdletName -Severity 0
                } Else {
                    #End of install/uninstall/Repair
                    Write-TempLog "ERROR: Temporary log folder [$($adtSession.LogTempFolder)] does not exist. Nothing to Merge or Compress." -source $CmdletName -Severity 3
                    Start-sleep -Seconds 7
                }
            }
        } Else {
            Write-TempLog "Not Compressing or Merging log files because `$AdtConfig.MergeNRollLogs.LogsAreCompressed is `$false in Config.psd1" -source $CmdletName
        }
    
        If ($PreOpenSession -eq $True) {
            #NOTE: We only Rotate-Logfiles before we open the PSADT Session to open up a 'slot' for the .log or the .zip file for when PSADT is done. 
            #Rotate-Logfiles rotates .log and .ZIP files to .bk# and _bk#.Zip files respectively.
            If ($AdtConfig.MergeNRollLogs.RotateLogFiles) {
                Write-TempLog "Calling Rotate-Logfiles... `$($adtSession.DeploymentType) is [$($adtSession.DeploymentType)]. " -Source $CmdletName
                Rotate-Logfiles -LogFileNameToRotate $DestinationArchiveFileName -LogFileParentFolder $LogPath
            } Else {
                Write-TempLog "Not Rotating log files.: `$AdtConfig.MergeNRollLogs.RotateLogFiles is `$false in Config.psd1" -source $CmdletName
            }
        } Else {
            Write-TempLog "Not Rotating Log files after session is closed." -Source $CmdletName
        }
    
        [String]$LogDash = '-' * 79	#dev Test
        Write-TempLog "$LogDash" -source $CmdletName -Severity 2
        Write-TempLog "-----  Log File Cleanup complete  -----" -source $CmdletName -Severity 2
        Write-TempLog "$LogDash" -source $CmdletName -Severity 2

    } Catch {
        $PreExitCode = $_.Exception.HResult
        Write-TempLog "Function [$CmdletName] failed: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage) `n$($_.Exception.InnerException) `n$PreExitCode"  -source $CmdletName -ForceToConsole
        Start-Sleep -Seconds 10
        ## Exit the script, returning the exit code to SCCM
        If (Test-Path -LiteralPath 'variable:HostInvocation') {
            $script:ExitCode = $PreExitCode; Exit
        }
        Else {
            Exit $PreExitCode
        }
    }
} #Invoke-MergeNRollLogs


##*===============================================
##* MARK: SCRIPT BODY
##*===============================================
#CAVEAT: The following code only runs UPON IMPORTING of this module
#Any variables created here cease to exist once importing is done unless defined in the Global scope ( $Global:VarName )
Try {
    # Insert Code that needs to run on Import


} Catch {
	$PreExitCode = $_.Exception.HResult
    Write-Error -Message "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] failed to load: `n$($_.Exception.Message)`n `n$($_.InvocationInfo.PositionMessage) `n$($_.Exception.InnerException) `n$PreExitCode" -ErrorAction 'Continue'
	Start-Sleep -Seconds 10
    ## Exit the script, returning the exit code to SCCM
    If (Test-Path -LiteralPath 'variable:HostInvocation') {
        $script:ExitCode = $PreExitCode; Exit
    }
    Else {
        Exit $PreExitCode
    }
}

# Announce successful importation of module w/o using Write-ADTLogEntry
Write-Host "Module [$($MyInvocation.MyCommand.ScriptBlock.Module.Name)] imported successfully." -ForegroundColor 'Green' -BackgroundColor 'Black'