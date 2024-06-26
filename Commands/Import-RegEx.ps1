﻿function Import-RegEx
{
    <#
        .Synopsis
            Imports Regular Expressions
        .Description
            Imports saved Regular Expressions.
        .Example
            Import-RegEx # Imports Regex from Irregular and the current directory.
        .Example
            Import-Regex -FromModule AnotherModule # Imports Regular Expressions stored in another module.
        .Example
            Import-RegEx -Name NextWord
        .Link
            Use-RegEx
        .Link
            New-RegEx
    #>
    [OutputType([nullable], [PSObject])]
    param(
        # The path to one or more files or folders containing regular expressions.
        # Files should be named $Name.regex.txt or $Name.regex.ps1
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [Alias('Fullname')]
        [string[]]$FilePath,

        # If provided, will get regular expressions from any number of already imported modules.
        [string[]]
        $FromModule,

        # One or more direct patterns to import
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string[]]
        $Pattern,

        # The Name of the Regular Expression.
        [Parameter(ValueFromPipelineByPropertyName=$true)]
        [string[]]
        $Name,

        # If set, will output the imported regular expressions.
        [switch]
        $PassThru
    )

    begin {
        # Initialize the library and metadata
        if (-not $script:_RegexLibrary) { $script:_RegexLibrary = @{}}
        if (-not $script:_RegexLibraryMetaData) { $script:_RegexLibraryMetaData = @{}}

        $importInvocation = $MyInvocation
        # Determine if we're being called from an Import-Module, and, if so, which one.
        $ModuleCaller =
            $(foreach ($cs in Get-PSCallStack) {
                if ($cs.InvocationInfo.MyCommand.Name -notlike '*.psm1') { continue }
                $cs.InvocationInfo.MyCommand.ScriptBlock.Module
                break
            })

        # We need to be able to write regexes that use other Regexes, so we need this fancy Regex to find Capture References.
        $SavedCaptureReferences = [Regex]::new(@'
(\(\?\<(?<NewCaptureName>\w+)\>)?
(?<!\()                   # Not preceeded by a (
    \?\<(?<CaptureName>\w+)\> # ?<CaptureName>
    (?<HasArguments>
        (?:
        \((?<Arguments>     # An open parenthesis
        (?>                 # Followed by...
            [^\(\)]+|       # any number of non-parenthesis character OR
            \((?<Depth>)|   # an open parenthesis (in which case increment depth) OR
            \)(?<-Depth>)   # a closed parenthesis (in which case decrement depth)
        )*(?(Depth)(?!))    # until depth is 0.
    )\)                      # followed by a closing parenthesis
)|
(?:
    \{(?<Arguments>     # An open bracket
    (?>                 # Followed by...
        [^\{\}]+|       # any number of non-bracket character OR
        \{(?<Depth>)|   # an open bracket (in which case increment depth) OR
        \}(?<-Depth>)   # a closed bracket (in which case decrement depth)
    )*(?(Depth)(?!))    # until depth is 0.
        )\}             # followed by a closing bracket
)
)?
'@, 'IgnoreCase, IgnorePatternWhitespace', '00:00:01')


        # We'll also need to replaced saved captures as we see them.
        $replaceSavedCapture = {
            $m = $args[0]
            $startsWithCapture = '(?<StartsWithCapture>\A\(\?\<(?<FirstCaptureName>\w+))>'
            $regex = $script:_RegexLibrary.($m.Groups["CaptureName"].ToString())
            if (-not $regex) { return $m }
            $regex =
                if ($regex -isnot [Regex]) {
                    if ($m.Groups["Arguments"].Success) {
                        $args = @($m.Groups["Arguments"].ToString() -split '(?<!\\),')
                        & $regex @args
                    } else {
                        & $regex
                    }
                } else {
                    $regex
                }
            if ($m.Groups["NewCaptureName"].Success) {
                if ($regex -match $startsWithCapture -and
                    $matches.FirstCaptureName -ne $m.Groups['NewCaptureName']) {
                    $repl= $regex -replace $startsWithCapture, "(?<$($m.Groups['NewCaptureName'])>"
                    $repl.Substring(0, $repl.Length - 1)
                } else {
                    "(?<$($m.Groups['NewCaptureName'].Value)>$regex$([Environment]::NewLine)"
                }
            } else {
                $regex
            }
        }

        # We'll need an internal command to handle importing regexes.

        $importRegexPattern = {
            process {
                $patternIn = $_
                $c = 0
                $rxLines =
                    @(if ($_ -is [IO.FileInfo]) { # If the regex came in from a file,
                        [IO.File]::ReadLines($_.Fullname) # read each line
                    } elseif ($_ -is [string]) { # Otherwise, split out newlines.
                        $_ -split '(?>\r\n|\n)'
                    } elseif ($_.Pattern) {
                        $_.Pattern -split '(?>\r\n|\n)'
                    })

                $name =
                    if ($_ -is [IO.FileInfo]) { # If the regex came from a file
                        if ($_.Directory.Name -ne 'RegEx') { # that wasn't beneath a Regex folder,
                            # Include the parent path
                            $dirPart = ($_.Directory.FullName.Substring($importPath.Length) -replace '(?:\\|/)RegEx(?:\\|/)','')
                            if (-not $dirPart) { $dirPart = $_.Directory.Name }
                            $dirPart + '_' + $_.Name -replace '\.regex\.txt$', ''
                        } else {
                            $_.Name -replace '\.regex\.txt$', ''
                        }
                    } elseif ($_ -is [string] -and $_ -match '(?<StartsWithCapture>\A\(\?\<(?<FirstCaptureName>\w+))>') {
                        $matches.FirstCaptureName
                    } else {
                        $_.Name
                    }

                $description = @( # The pattern's description will be
                    if ($patternIn.Description) {
                        $patternIn.Description
                    }
                    for (;$c -lt $rxLines.Length;$c++) { # Any number of initial lines starting with comments.
                        if ($rxLines[$c] -notlike '#*') { break }
                        $rxLines[$c].TrimStart('#').Trim()
                    }
                ) -join [Environment]::NewLine

                $rx =
                    @(for (;$c -lt $rxLines.Length;$c++) {
                        $rxLines[$c]
                    }) -join [Environment]::NewLine

                $regex = [PSCustomObject][Ordered]@{  # Create the RegEx object
                    PSTypeName   = 'Irregular.RegEx'
                    Name = $name ; Description = $description
                    Pattern = $rx; Path = if ($patternIn.Path) { $patternIn.Path} else { $in.FullName }
                    IsGenerator = $false;IsPattern = $true
                }

                $regex =
                    # If it contained other RegExes
                    if ($regex.IsPattern -as [bool] -and $SavedCaptureReferences.IsMatch($rx)) {
                        # try replacing them
                        $firstReplaceTry = $savedCaptureReferences.Replace($rx, $replaceSavedCapture)
                        if ($firstReplaceTry -ne $rx -and -not $savedCaptureReferences.IsMatch($firstReplaceTry)) {
                            $regex.Pattern = $firstReplaceTry
                            $regex
                        } else {
                            # If we couldn't, try, try again.
                            $regex.Pattern  = if ($firstReplaceTry) { $firstReplaceTry } else { $rx }
                            $tryTryAgain.Enqueue($regex)
                        }
                    } else {
                        $regex
                    }

                    return $regex
            }
        }

        # We want an internal function to keep import a single file.
        $importRegexFile = {
            process {
                $in = $_
                # See if it matches our naming convention
                $nameOk = $_.Name -match '^(?<Name>.*?)\.regex\.((?<IsGenerator>ps1)|(?<IsPattern>txt))$'
                # If it doesn't, bounce
                if (-not $nameOk) { return }
                $n = $matches.Name
                if ($Name -or $PSBoundParameters.ContainsKey('Name')) { # If we're filtering imports by name
                    :FoundIt do { # check if we want to import this one.
                        foreach ($pn in $name) {
                            if ($n -like $pn) {break FoundIt}
                        }
                        return
                    } while ($false)
                }

                if ($matches.IsGenerator) { # If the file was a generator
                    $findDescription = [Regex]::new(@'
\.Description # Description Start
\s{0,} # Optional Whitespace
(?<Content>(.|\s)+?(?=(\.\w+|\#\>|\z))) # Anything until the next .\word or \comment
'@, 'IgnoreCase,IgnorePatternWhitespace') # find it's description from inline help
                $generatorScript =
                    $ExecutionContext.SessionState.InvokeCommand.GetCommand($in.FullName, 'ExternalScript')

                    $matched = $findDescription.Match($generatorScript.ScriptContents)
                $gn = # then determine the name of the Regex
                    $(if ($in.Directory.Name -eq 'RegEx') {
                        $n # (if it's in a directory called Regex, it's the file name)
                    } else {
                        $dirPart =
                            ($in.Directory.FullName.Substring($importPath.Length) -replace
                            '(?:\\|/)RegEx(?:\\|/)','')
                        if (-not $dirPart) { $dirPart = $in.Directory.Name } # Otherwise, it's directoryname_$n
                        $dirPart + '_' + $n
                    })
                return [PSCustomObject][Ordered]@{
                    PSTypeName   = 'Irregular.RegEx'
                    Name = $gn   ; Description = $matched.Groups["Content"].ToString();
                    Pattern = ''; Path = $in.FullName
                    IsGenerator = $true;IsPattern = $false
                }
            }
            $_ | & $importRegexPattern
        }
    }

        $importIntoLibrary  = {
            process {
                $regex = $_
                $script:_RegexLibrary[$regEx.Name] =
                    if ($regex.IsGenerator) {
                        $ExecutionContext.SessionState.InvokeCommand.GetCommand($regex.Path, 'ExternalScript')
                    } else {
                        try {
                            [Regex]::new(
                                ("(?<$($regex.Name)>", $($regex.Pattern -join [Environment]::NewLine), ')' -join [Environment]::NewLine),
                                'IgnoreCase,IgnorePatternWhitespace', '00:00:05.00')
                        } catch {
                            $PSCmdlet.WriteError(
                                [Management.Automation.ErrorRecord]::new("Could not import $($regex.Name): $($_.Exception.Message)",$_.Exception, 'OpenError',$_)
                            )
                        }
                    }
                $script:_RegexLibraryMetaData[$regex.Name] = $regex
                if ($PassThru) { $regex }
                if ($importInvocation.InvocationName -eq '&' -or $importInvocation.InvocationName -eq '.') { return }
                $foundAlias =
                    if ($ModuleCaller) {
                        if ($ModuleCaller -and $ModuleCaller.ExportedAliases.Count) {
                            $ModuleCaller.ExportedAliases["?<$($regex.Name)>"]
                        } else {
                            $true
                        }

                    } else {
                        $ExecutionContext.SessionState.InvokeCommand.GetCommand("?<$($regex.Name)>",'Alias')
                    }
                if ($regex -and -not $foundAlias) {
                    $tempModule =
                        New-Module -Name "?<$($regex.Name)>" -ScriptBlock {
                            Set-Alias "?<$args>" Use-RegEx; Export-ModuleMember -Alias *
                        } -ArgumentList $regex.name |
                            Import-Module -Global -PassThru
                    if (-not $script:_RegexTempModules) {
                        $script:_RegexTempModules = [Collections.Queue]::new()
                    }
                    $script:_RegexTempModules.Enqueue($tempModule)
                }
            }
        }
    }

    process {
        #region Determine the Path List
        $pathList =
            & {
                if ($Pattern) { return }
                if ($FilePath) { # If any file paths were provided
                    foreach ($fp in $filePath){ # resolve them
                        $ExecutionContext.SessionState.Path.GetResolvedPSPathFromPSPath($fp)
                    }
                    return # and use just this pathlist.
                }

                if ($FromModule) { # If -FromModule was passed,
                    $loadedModules = Get-Module # get all loaded modules.
                    $loadedModuleNames =
                    foreach ($lm in $loadedModules) { # get their names
                        $lm.Name
                    }
                    $OkModules =
                        foreach ($fm in $fromModule) { # filter the ones that are OK
                            $loadedModuleNames -like $fm
                        }
                    foreach ($lm in $loadedModules) {
                        if ($OkModules -contains $lm.Name) {
                            $lm | Split-Path
                        }
                    }
                } else {
                    if ($MyInvocation.MyCommand.ScriptBlock.Module) {
                        $MyInvocation.MyCommand.ScriptBlock.Module | Split-Path
                    } else {
                        $MyInvocation.MyCommand.ScriptBlock.File | Split-Path | Split-Path
                    }
                    
                }
            }
        #endregion Determine the Path List


        $tryTryAgain = [Collections.Queue]::new() # Create a queue to store retries

        #region Get RegEx files
        $pathList = $pathList | Select-Object -Unique
        foreach ($p in $pathList) {
            $p = "$p"
            if ([IO.Directory]::Exists($p) -or [IO.File]::Exists($p)) {
                @(
                if ([IO.File]::Exists($p))
                {
                    [IO.FileInfo]$p
                    $ImportPath = ([IO.FileInfo]$p).Directory.FullName
                } elseif ([IO.Directory]::Exists($p))
                {
                    $ImportPath = $p
                    ([IO.DirectoryInfo]"$p").EnumerateFiles('*', 'AllDirectories')
                })  |
                    & $importRegexFile |
                    . $importIntoLibrary
            }
        }
        #endregion Get RegEx files

        #region Import Patterns Directly
        if ($Pattern) {
            $Pattern |
                & $importRegexPattern |
                . $importIntoLibrary
        }
        #endregion Import Patterns Directly

        #region Retry Nested Imports
        $patience = 1kb
        @(while ($tryTryAgain.Count) {
        $tryAgain = $tryTryAgain.Dequeue()
        $countBefore = $tryTryAgain.Count
        $tryAgain | & $importRegexPattern
        $countAfter = $tryTryAgain.Count
        if ($countAfter -gt $countBefore) {
            $patience--
        }
        if ($patience -le 0) {
            Write-Verbose "Patience Exceeded.  Expressions most likely have circular references" #-ErrorId Irregular.Import.Lost.Patience
            break
            }
        }) | . $importIntoLibrary
        #endregion Retry Nested Imports
    }
}
