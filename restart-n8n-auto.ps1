# restart-n8n-auto.ps1
param(
    [int]$TimeoutSeconds = 30
)

function Write-StyledMessage {
    param(
        [string]$Message,
        [string]$Type = "Info",
        [string]$Icon = ""
    )
    
    switch ($Type) {
        "Success" { 
            Write-Host "$Icon $Message" -ForegroundColor Green 
        }
        "Warning" { 
            Write-Host "$Icon $Message" -ForegroundColor Yellow 
        }
        "Error" { 
            Write-Host "$Icon $Message" -ForegroundColor Red 
        }
        "Info" { 
            Write-Host "$Icon $Message" -ForegroundColor Cyan 
        }
        "Header" { 
            Write-Host ""
            Write-Host "=======================================================================" -ForegroundColor Magenta
            Write-Host " $Icon $Message" -ForegroundColor White -BackgroundColor Magenta
            Write-Host "=======================================================================" -ForegroundColor Magenta
            Write-Host ""
        }
        "Divider" {
            Write-Host ""
            Write-Host "-----------------------------------------------------------------------" -ForegroundColor DarkGray
            Write-Host ""
        }
        default { 
            Write-Host "$Icon $Message" -ForegroundColor White 
        }
    }
}

function Get-NgrokUrl {
    param([int]$MaxRetries = 10)
    
    for ($i = 1; $i -le $MaxRetries; $i++) {
        try {
            Write-StyledMessage "Attempting to fetch ngrok URL (try $i/$MaxRetries)..." "Info" "[INFO]"
            $response = Invoke-RestMethod -Uri "http://localhost:4040/api/tunnels" -Method Get
            
            if ($response.tunnels -and $response.tunnels.Count -gt 0) {
                $httpsUrl = $response.tunnels | Where-Object { $_.proto -eq "https" } | Select-Object -First 1
                if ($httpsUrl) {
                    return $httpsUrl.public_url
                }
                
                # If no HTTPS available, take the first one
                return $response.tunnels[0].public_url
            }
        }
        catch {
            Write-StyledMessage "Failed to get ngrok URL: $($_.Exception.Message)" "Warning" "[WARN]"
        }
        
        Start-Sleep -Seconds 2
    }
    
    throw "Could not obtain ngrok URL after $MaxRetries attempts"
}

function Stop-NgrokProcesses {
    Write-StyledMessage "Stopping existing ngrok processes..." "Info" "[STOP]"
    Get-Process -Name "ngrok" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    Write-StyledMessage "Ngrok processes stopped" "Success" "[OK]"
}

function Start-NgrokTunnel {
    Write-StyledMessage "Starting ngrok tunnel..." "Info" "[START]"
    
    # Start ngrok in background
    $ngrokProcess = Start-Process -FilePath "ngrok" -ArgumentList "http", "5678" -WindowStyle Hidden -PassThru
    
    # Wait for ngrok to initialize
    Write-StyledMessage "Waiting for ngrok to initialize..." "Info" "[WAIT]"
    Start-Sleep -Seconds 5
    
    return $ngrokProcess
}

try {
    Write-StyledMessage "N8N AUTOMATIC RESTART PROCESS" "Header" "[N8N]"
    
    # 1. Stop existing ngrok processes
    Write-StyledMessage "STEP 1: Cleaning up existing ngrok processes" "Info" "[STEP1]"
    Stop-NgrokProcesses
    
    Write-StyledMessage "" "Divider"
    
    # 2. Stop and remove n8n container
    Write-StyledMessage "STEP 2: Managing n8n container" "Info" "[STEP2]"
    Write-StyledMessage "Stopping n8n-main container..." "Info" "[DOCKER]"
    docker stop n8n-main 2>$null
    
    Write-StyledMessage "Removing n8n-main container..." "Info" "[DOCKER]"
    docker rm n8n-main 2>$null
    Write-StyledMessage "Container cleanup completed" "Success" "[OK]"
    
    Write-StyledMessage "" "Divider"
    
    # 3. Start ngrok tunnel
    Write-StyledMessage "STEP 3: Setting up ngrok tunnel" "Info" "[STEP3]"
    $ngrokProcess = Start-NgrokTunnel
    Write-StyledMessage "Ngrok tunnel started successfully" "Success" "[OK]"
    
    Write-StyledMessage "" "Divider"
    
    # 4. Get ngrok URL
    Write-StyledMessage "STEP 4: Retrieving ngrok URL" "Info" "[STEP4]"
    $NgrokUrl = Get-NgrokUrl
    Write-StyledMessage "Ngrok URL obtained: $NgrokUrl" "Success" "[URL]"
    
    Write-StyledMessage "" "Divider"
    
    # 5. Create new n8n container with ngrok URL
    Write-StyledMessage "STEP 5: Creating new n8n container" "Info" "[STEP5]"
    Write-StyledMessage "Launching n8n with URL: $NgrokUrl" "Info" "[DOCKER]"
    docker run -d --name n8n-main -p 5678:5678 `
      -e N8N_HOST=0.0.0.0 `
      -e N8N_PORT=5678 `
      -e N8N_PROTOCOL=https `
      -e N8N_EDITOR_BASE_URL=$NgrokUrl `
      -e WEBHOOK_URL=$NgrokUrl `
      -e VUE_APP_URL_BASE_API=$NgrokUrl `
      -e N8N_RUNNERS_ENABLED=true `
      -v C:\docker\n8n-data:/home/node/.n8n `
      n8nio/n8n
    
    if ($LASTEXITCODE -eq 0) {
        Write-StyledMessage "" "Divider"
        Write-StyledMessage "PROCESS COMPLETED SUCCESSFULLY!" "Header" "[SUCCESS]"
        Write-StyledMessage "n8n is now running with URL: $NgrokUrl" "Success" "[READY]"
        Write-StyledMessage "Access your n8n instance at: $NgrokUrl" "Warning" "[ACCESS]"
        Write-StyledMessage "" "Divider"
        Write-StyledMessage "To stop everything: docker stop n8n-main; Get-Process ngrok | Stop-Process" "Info" "[TIP]"
        Write-Host ""
    } else {
        throw "Failed to create Docker container"
    }
}
catch {
    Write-StyledMessage "" "Divider"
    Write-StyledMessage "PROCESS FAILED!" "Header" "[ERROR]"
    Write-StyledMessage "Error: $($_.Exception.Message)" "Error" "[FAIL]"
    
    # Cleanup on error
    Write-StyledMessage "Cleaning up resources..." "Warning" "[CLEANUP]"
    docker stop n8n-main 2>$null
    docker rm n8n-main 2>$null
    Stop-NgrokProcesses
    
    Write-StyledMessage "Cleanup completed" "Info" "[OK]"
    Write-Host ""
    exit 1
}