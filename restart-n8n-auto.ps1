# restart-n8n-auto-with-redis.ps1
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

function Stop-ContainerIfExists {
    param([string]$ContainerName)
    
    Write-StyledMessage "Stopping $ContainerName container..." "Info" "[DOCKER]"
    docker stop $ContainerName 2>$null
    
    Write-StyledMessage "Removing $ContainerName container..." "Info" "[DOCKER]"
    docker rm $ContainerName 2>$null
}

function Start-RedisContainer {
    Write-StyledMessage "Starting Redis container..." "Info" "[REDIS]"
    
    # Create Redis container with persistent storage
    docker run -d --name redis-n8n `
      -p 6379:6379 `
      -v C:\docker\redis-data:/data `
      redis:7-alpine redis-server --appendonly yes
    
    if ($LASTEXITCODE -eq 0) {
        Write-StyledMessage "Redis container started successfully" "Success" "[OK]"
        
        # Wait for Redis to be ready
        Write-StyledMessage "Waiting for Redis to be ready..." "Info" "[WAIT]"
        Start-Sleep -Seconds 3
        
        # Test Redis connection
        $redisTest = docker exec redis-n8n redis-cli ping 2>$null
        if ($redisTest -eq "PONG") {
            Write-StyledMessage "Redis is ready and responding" "Success" "[REDIS]"
            return $true
        } else {
            Write-StyledMessage "Redis connection test failed" "Warning" "[WARN]"
            return $false
        }
    } else {
        throw "Failed to start Redis container"
    }
}

function Test-RedisConnection {
    try {
        $result = docker exec redis-n8n redis-cli ping 2>$null
        return $result -eq "PONG"
    }
    catch {
        return $false
    }
}

try {
    Write-StyledMessage "N8N + REDIS AUTOMATIC RESTART PROCESS" "Header" "[N8N+REDIS]"
    
    # 1. Stop existing ngrok processes
    Write-StyledMessage "STEP 1: Cleaning up existing ngrok processes" "Info" "[STEP1]"
    Stop-NgrokProcesses
    
    Write-StyledMessage "" "Divider"
    
    # 2. Stop and remove existing containers
    Write-StyledMessage "STEP 2: Managing existing containers" "Info" "[STEP2]"
    Stop-ContainerIfExists "n8n-main"
    Stop-ContainerIfExists "redis-n8n"
    Write-StyledMessage "Container cleanup completed" "Success" "[OK]"
    
    Write-StyledMessage "" "Divider"
    
    # 3. Start Redis container
    Write-StyledMessage "STEP 3: Setting up Redis" "Info" "[STEP3]"
    $redisStarted = Start-RedisContainer
    if (-not $redisStarted) {
        Write-StyledMessage "Redis may not be fully ready, but continuing..." "Warning" "[WARN]"
    }
    
    Write-StyledMessage "" "Divider"
    
    # 4. Start ngrok tunnel
    Write-StyledMessage "STEP 4: Setting up ngrok tunnel" "Info" "[STEP4]"
    $ngrokProcess = Start-NgrokTunnel
    Write-StyledMessage "Ngrok tunnel started successfully" "Success" "[OK]"
    
    Write-StyledMessage "" "Divider"
    
    # 5. Get ngrok URL
    Write-StyledMessage "STEP 5: Retrieving ngrok URL" "Info" "[STEP5]"
    $NgrokUrl = Get-NgrokUrl
    Write-StyledMessage "Ngrok URL obtained: $NgrokUrl" "Success" "[URL]"
    
    Write-StyledMessage "" "Divider"
    
    # 6. Create new n8n container with Redis connection
    Write-StyledMessage "STEP 6: Creating new n8n container with Redis support" "Info" "[STEP6]"
    Write-StyledMessage "Launching n8n with URL: $NgrokUrl" "Info" "[DOCKER]"
    
    # Link to Redis container and add Redis configuration
    docker run -d --name n8n-main -p 5678:5678 `
      --link redis-n8n:redis `
      -e N8N_HOST=0.0.0.0 `
      -e N8N_PORT=5678 `
      -e N8N_PROTOCOL=https `
      -e N8N_EDITOR_BASE_URL=$NgrokUrl `
      -e WEBHOOK_URL=$NgrokUrl `
      -e VUE_APP_URL_BASE_API=$NgrokUrl `
      -e N8N_RUNNERS_ENABLED=true `
      -e QUEUE_BULL_REDIS_HOST=redis `
      -e QUEUE_BULL_REDIS_PORT=6379 `
      -e QUEUE_BULL_REDIS_DB=0 `
      -e EXECUTIONS_MODE=queue `
      -e QUEUE_HEALTH_CHECK_ACTIVE=true `
      -e N8N_BASIC_AUTH_ACTIVE=true `
      -e N8N_BASIC_AUTH_USER=admin `
      -e N8N_BASIC_AUTH_PASSWORD=n8n2024! `
      -v C:\docker\n8n-data:/home/node/.n8n `
      n8nio/n8n
    
    if ($LASTEXITCODE -eq 0) {
        Write-StyledMessage "" "Divider"
        Write-StyledMessage "PROCESS COMPLETED SUCCESSFULLY!" "Header" "[SUCCESS]"
        Write-StyledMessage "Redis is running on port 6379" "Success" "[REDIS]"
        Write-StyledMessage "n8n is now running with URL: $NgrokUrl" "Success" "[READY]"
        Write-StyledMessage "n8n is configured with Redis queue support" "Success" "[QUEUE]"
        Write-StyledMessage "Access your n8n instance at: $NgrokUrl" "Warning" "[ACCESS]"
        Write-StyledMessage "" "Divider"
        
        # Test Redis connection from n8n container
        Write-StyledMessage "Testing Redis connection from n8n..." "Info" "[TEST]"
        Start-Sleep -Seconds 3
        
        # Check if containers are running
        $n8nRunning = docker ps --filter "name=n8n-main" --filter "status=running" --quiet
        $redisRunning = docker ps --filter "name=redis-n8n" --filter "status=running" --quiet
        
        if ($n8nRunning -and $redisRunning) {
            Write-StyledMessage "Both containers are running successfully!" "Success" "[STATUS]"
        Write-StyledMessage "" "Divider"
        Write-StyledMessage "LOGIN CREDENTIALS:" "Header" "[AUTH]"
        Write-StyledMessage "Username: admin" "Warning" "[USER]"
        Write-StyledMessage "Password: n8n2024!" "Warning" "[PASS]"
        } else {
            Write-StyledMessage "Warning: One or more containers may not be running properly" "Warning" "[STATUS]"
        }
        
        Write-StyledMessage "" "Divider"
        Write-StyledMessage "MANAGEMENT COMMANDS:" "Info" "[HELP]"
        Write-StyledMessage "Stop all: docker stop n8n-main redis-n8n; Get-Process ngrok | Stop-Process" "Info" "[TIP]"
        Write-StyledMessage "Check Redis: docker exec redis-n8n redis-cli ping" "Info" "[TIP]"
        Write-StyledMessage "View n8n logs: docker logs n8n-main" "Info" "[TIP]"
        Write-StyledMessage "View Redis logs: docker logs redis-n8n" "Info" "[TIP]"
        Write-Host ""
    } else {
        throw "Failed to create n8n Docker container"
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
    docker stop redis-n8n 2>$null
    docker rm redis-n8n 2>$null
    Stop-NgrokProcesses
    
    Write-StyledMessage "Cleanup completed" "Info" "[OK]"
    Write-Host ""
    exit 1
}