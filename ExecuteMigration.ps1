param([string] $dataToolsPath)


function IsDBInstalled { 
    param([string] $connectionString =  $(throw "Please specify a connection string."))

    $exists = $false

    try
    {
        $connection = new-object system.data.SqlClient.SQLConnection($connectionString)
        $connection.Open()
        $exists = $true
        $connection.Close()
    }
    catch
    {
        Write-Host("Failed to connect to the target DB or DB doesn't exist. Connection String: $($connectionString)")
    }

    return $exists
}

function Invoke-SQL {
    param(
        [string] $connectionString =  $(throw "Please specify a connection string."),
        [string] $sqlCommand = $(throw "Please specify a query.")
    )
        
    $connection = new-object system.data.SqlClient.SQLConnection($connectionString)
    $command = new-object system.data.sqlclient.sqlcommand($sqlCommand,$connection)
    $connection.Open()

    $adapter = New-Object System.Data.sqlclient.sqlDataAdapter $command
    $dataset = New-Object System.Data.DataSet
    $adapter.Fill($dataSet) | Out-Null

    $connection.Close()
    return $dataSet.Tables
}

function Update-DB {
    param(
    [string] $contextDllName = $(throw "Please specify the context dll"),
    [string] $EFToolsDirectoryPath = "content",
    [string] $targetMigration = "",
    [string] $appConfigDirectoryPath = "",
    [string] $appConnectionStringName = "",
    [string] $configFileName = "web.config",
    [string] $configurationType = "",
    [bool] $forcedMigration = $false,
    [bool] $useAppContextDll = $false
    )

# Get the exe name based on the directory
$contentPath = (Join-Path $EFToolsDirectoryPath "content")
$originalMigrateExe = (Join-Path $EFToolsDirectoryPath "content\migrate.exe")
$migrateExe = $originalMigrateExe
$contextDllPath = (Join-Path $contentPath $contextDllName)
$binPath = $contentPath
$appConfigFile = (Join-Path $contentPath $configFileName)

#Checks if migration.exe exists
if(![System.IO.File]::Exists($originalMigrateExe)){
    throw "migrate.exe does not exist on the content folder: $($EFToolsDirectoryPath)"
}

#Checks the web app directory path
if(![System.IO.Directory]::Exists($appConfigDirectoryPath)){
    Write-Host "App directory doesn't exist. $($appConfigDirectoryPath). Will be referencing $($contentPath) for $($configFileName)."
    $useAppContextDll = $false
} else {
    Write-Host "App Package was installed to: $appConfigDirectoryPath"
}
        
#Use the Web App Context Dll, not the ones bundled in the migrate.exe
if ($useAppContextDll) {

    $appConfigFile = (Join-Path $appConfigDirectoryPath $configFileName)

    $binPath = Join-Path $appConfigDirectoryPath "bin"
    $migrateExe = Join-Path $binPath "\migrate.exe"
    if (-Not(Test-Path $migrateExe)) {
        # Move migrate.exe to ASP.NET Project's bin folder as per https://msdn.microsoft.com/de-de/data/jj618307.aspx?f=255&MSPPError=-2147217396
        Copy-Item $originalMigrateExe -Destination $binPath
        Write-Host("Copied $originalMigrateExe into $binPath")
    }

    #Locate Assembly with DbContext class
    $contextDllPath = Join-Path $binPath $contextDllName
} 

if (-Not(Test-Path $contextDllPath)){
    throw ("Unable to locate assembly file with DbContext class. Specifed path $contextDllPath does not exist.")
}

#Locate config file. Migrate.exe needs it for some reason, even if connection string is provided
if (-Not(Test-Path $appConfigFile)){
    throw ("Unable to locate configuration file - $appConfigFile")
}

Write-Host("Using $contextDllName from $contextDllPath")
Write-Host "Config Path:" $appConfigFile
Write-Host "Context Path:" $contextDllPath
Write-Host "Migrate Path:" $migrateExe

$startupDirectory = " /startUpDirectory='$($binPath)' "
$force = If ($forcedMigration) { " /force " } Else { "" }
$configurationType = If ($configurationType.Length -gt 0) { " $($configurationType)" } Else { "" }

cd $contentPath

write-host "Working Dir: "$(get-location)

$migrateCommand = "& ""$migrateExe"" ""$contextDllName"" $configurationType /connectionStringName=""$appConnectionStringName"" /targetMigration=""$targetMigration"" /startupConfigurationFile=""$appConfigFile"" $startupDirectory $force /Verbose"

Write-Host "##octopus[stderr-error]" # Stderr is an error
Write-Host "Executing: " $migrateCommand
Write-Host 

Invoke-Expression $migrateCommand | Write-Host

if ($LastExitCode -ne 0) {
    throw "Migrate.exe completed with non-zero exit code. Please check the results." 
}

}

function Get-Last-Common-Migration {
    param(
    [array] $releaseMigrations = $(throw "Must specify release migrations"),
    [array] $dbMigrations = $(throw "Must specify DB migrations")
    )
    $i = 0;
    $done = $false

    [hashtable]$Return = @{}

    $Return.tipMigration = ""
    $Return.lastCommonMigration = ""

    foreach($migration in $dbMigrations) {
        $Return.tipMigration = $migration["MigrationId"]

        if (-not($done)) {
            if($migration["MigrationId"] -eq $releaseMigrations[$i])
            {
                $Return.lastCommonMigration = $migration["MigrationId"]
                $i++
            }
            else {
                $done = $true
            }
        }
    }

    return $Return
}

# End of Functions #
# --------------- #
# Main #

function ExecuteMigration {
    param(
        [string] $migrationHistoryConnString = $(throw "Must specify ConnectionString"),
        [string] $toolsPackageDirectoryPath =  $(throw "Must specify toolsPackageDirectoryPath"),
        [string] $migrationListTextFile = $(throw "Must specify migrationListTextFile"),
        [string] $appConnStringName = $(throw "Must specify appConnStringName"),
        [string] $configurationType = $(throw "Must specify configurationType")
    )

    #sets the package path provided by octopi deploy. Note: $toolsPackageDirectoryPath, $appDirectoryPath and $migrationHistoryConnString will be replaced by Octopus variables.
    $contextDll =  'SIDD.Data.dll'
    $releaseMigrationListFullPath = (Join-Path $toolsPackageDirectoryPath "content\$($migrationListTextFile)")
    
    #-migrationHistoryConnString "Data Source=localhost;Initial Catalog=Beyonder;Integrated Security=True;MultipleActiveResultSets=True;" -toolsPackageDirectoryPath "C:\Users\Administrator\Downloads\SIDD.Data.Tools.1.0.14921-develop" -migrationListTextFile "beyonder-migration.txt" -appConnStringName "Beyonder-DB" -configurationType "Beyonder"
    $appDirectoryPath = $toolsPackageDirectoryPath
    $forcedMigration = $true    
    $migrationSchemaOwner = "dbo"

    #Checks if Migration.txt exists. Note: Migration.txt comes from a post-build in the tools project (which should consist your data project)
    if(![System.IO.File]::Exists($releaseMigrationListFullPath)){
        Write-Host "Migration List File [$($releaseMigrationListFullPath)] does not exist. Will be skipping the entire target migration check/update process."
        Exit 1
    }

    try {

        Write-Host "Starting EF Migration Script..."
        Write-Host "EFToolsBaseFolder: $($toolsPackageDirectoryPath)"

        #Get the list of migrations from the current release
        $releaseMigrations = @()
        Get-Content $releaseMigrationListFullPath | Foreach-Object{
            # Remove .cs
            $releaseMigrations += $_ -replace '\.cs$', ''
        }

        $releaseMigrationTip = $releaseMigrations[-1]
        if ($($releaseMigrationTip) -eq '') {
            Write-Host "There's no release tip found on the migration.txt"
        }

        Write-Host "Target Release Migration Tip: $($releaseMigrationTip)"

        # Get all current migration from the target DB
        $migrationsQuery = "IF (EXISTS (SELECT * 
                        FROM INFORMATION_SCHEMA.TABLES 
                        WHERE TABLE_SCHEMA = '$($migrationSchemaOwner)' 
                        AND  TABLE_NAME = '__MigrationHistory'))
                        SELECT MigrationId FROM [$($migrationSchemaOwner)].[__MigrationHistory]
                    ELSE 
                        SELECT '' as MigrationId where 1 = 0"

        Write-Host $query

        $isDBexist = IsDBInstalled $migrationHistoryConnString

        # If the release migration tip hasn't been found, setting the migrationToApply to empty will just update DB migration normally, 
        # otherwise it targets the migration specified on the tip of the release
        $migrationToApply = ""
        $isRollback = $false

        If ($isDBexist) {
        
            Write-Host "Target database found."
            $existingMigrationResults = Invoke-SQL -sqlCommand $migrationsQuery -connectionString $migrationHistoryConnString

            If ($existingMigrationResults.Rows.Count -gt 0) {
                #Find the last common migration between the txt file and the DB history
                $existingMigrations = Get-Last-Common-Migration -releaseMigrations $releaseMigrations -dbMigrations $existingMigrationResults.Rows

                Write-Host "Current Tip Migration: $($existingMigrations.tipMigration)"
                Write-Host "New Tip Migration: $($releaseMigrationTip)"
                Write-Host "Latest Common Migration: $($existingMigrations.lastCommonMigration)"

                $isRollback = $false

                if (-not($existingMigrations.tipMigration -eq $existingMigrations.lastCommonMigration)) {
                    Write-Host "Rolling back to latest common migration"
                    $migrationToApply = $existingMigrations.lastCommonMigration
                    $isRollback = $true
                }
            } else {
                Write-Host "No existing migration found for this release. Will execute the migration as normal."
            }

        } else {
            Write-Host "DB does not exist. Will attempt to execute the migration."
        }

        # Run update db through migrate.exe
        Update-DB -targetMigration $migrationToApply -EFToolsDirectoryPath $toolsPackageDirectoryPath -contextDll $contextDll -useAppContextDll  $isRollback -AppConnectionStringName $appConnStringName -AppConfigDirectoryPath $appDirectoryPath -altEFConnectionString $migrationHistoryConnString -forced $forcedMigration -configurationType $configurationType
        Write-Host "Migration Succeeded."

        if($isRollback){
            Write-Host "Rollback complete. Now applying $($releaseMigrationTip), and running seed method."
            # Run update db through migrate.exe
            Update-DB -targetMigration $releaseMigrationTip -EFToolsDirectoryPath $toolsPackageDirectoryPath -contextDll $contextDll -useAppContextDll  $false -AppConnectionStringName $appConnStringName -AppConfigDirectoryPath $appDirectoryPath -altEFConnectionString $migrationHistoryConnString -forced $forcedMigration -configurationType $configurationType
            Write-Host "Migration Succeeded."
        }
    }
    catch {
        Write-Host "##octopus[stderr-error]"
        Write-Host "Error: " $_.Exception.Message
        Write-Host "Stack Trace: " $_.Exception.StackTrace
        write-error "$cmd failed with exit code: $LastExitCode"
        Write-Host "Migration Failed."
        Exit 1 
    }
}


$Beyonder = [PSCustomObject]@{
    name="Beyonder-DB" 
    catalog="Beyonder"
    configName = "Beyonder"
}
$Deployment = [PSCustomObject]@{
    name="Deployment-DB" 
    catalog="SiddDeployment"
    configName = "Deployment"
}
$SiddLogs = [PSCustomObject]@{
    name="SiddLogs-DB" 
    catalog="SiddLog"
    configName = "SiddLogs"
}
$Metrics = [PSCustomObject]@{
    name="Metrics-DB"
    catalog="Metrics"
    configName = "Metrics"
}

@($Beyonder, $Metrics, $Deployment, $SiddLogs ) | ForEach-Object -Process {
    $migrationHistoryConnString = "Data Source=localhost;Initial Catalog=" + $_.catalog + ";Integrated Security=True;MultipleActiveResultSets=True;"    
    $migrationFile = $_.configName + "-migration.txt"
    ExecuteMigration -migrationHistoryConnString  $migrationHistoryConnString -toolsPackageDirectoryPath $dataToolsPath -migrationListTextFile $migrationFile -appConnStringName $_.name -configurationType $_.configName
}