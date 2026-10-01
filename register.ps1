$registry = "http://localhost:4873"

Write-Host "========================================"
Write-Host " Verdaccio npm Register"
Write-Host "========================================"
Write-Host ""
Write-Host "Registry:"
Write-Host "  $registry"
Write-Host ""

# 检查 Verdaccio 是否运行
$connections = Get-NetTCPConnection `
    -LocalPort 4873 `
    -State Listen `
    -ErrorAction SilentlyContinue

if ($null -eq $connections) {
    Write-Host "ERROR: Verdaccio is not running."
    Write-Host ""
    Write-Host "Please start Verdaccio first:"
    Write-Host "  run-start-background.bat"
    Write-Host ""
    exit 1
}

Write-Host "Verdaccio is running."
Write-Host ""

# 测试 Registry
try {
    $response = Invoke-WebRequest `
        -Uri "$registry/-/ping" `
        -UseBasicParsing `
        -TimeoutSec 3

    if ($response.StatusCode -ne 200) {
        Write-Host "ERROR: Verdaccio ping failed."
        exit 1
    }
}
catch {
    Write-Host "ERROR: Cannot connect to Verdaccio."
    Write-Host $_.Exception.Message
    exit 1
}

Write-Host "Registry is reachable."
Write-Host ""

# Read credentials:
#   - Piped stdin (web console): three lines - username / password / email.
#     npm 11 login/adduser prompts no longer accept piped stdin, so we call
#     the registry API directly: PUT /-/user/org.couchdb.user:<name>
#     (the same protocol behind npm adduser).
#   - Interactive (double-click bat): typed input, password masked.
if ([Console]::IsInputRedirected) {
    $username = [Console]::In.ReadLine()
    $password = [Console]::In.ReadLine()
    $email    = [Console]::In.ReadLine()
}
else {
    $username = Read-Host "Username"
    $secure   = Read-Host "Password" -AsSecureString
    $bstr     = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    $password = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    $email    = Read-Host "Email"
}

$username = "$username".Trim()
$email    = "$email".Trim()

if (-not $username -or -not $password) {
    Write-Host ""
    Write-Host "ERROR: username and password are required."
    exit 1
}

if ($username -notmatch '^[a-zA-Z0-9][a-zA-Z0-9._-]*$') {
    Write-Host ""
    Write-Host "ERROR: invalid username '$username'."
    Write-Host "Allowed: letters, digits, '.', '_', '-', and it cannot start with '.' or '-'."
    exit 1
}

if (-not $email) { $email = "nobody@localhost" }

# Call the registry user registration API
$body = @{
    name     = $username
    password = $password
    email    = $email
    type     = "user"
    roles    = @()
    date     = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
} | ConvertTo-Json

Write-Host ""
Write-Host "Registering user '$username'..."
Write-Host ""

$token = $null

try {
    $resp = Invoke-RestMethod `
        -Method Put `
        -Uri "$registry/-/user/org.couchdb.user:$username" `
        -ContentType "application/json; charset=utf-8" `
        -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) `
        -TimeoutSec 15

    if ($resp.ok) {
        Write-Host "OK: $($resp.ok)"
    }
    else {
        Write-Host "OK: user '$username' registered."
    }

    $token = $resp.token
}
catch {
    Write-Host "ERROR: registration failed."
    $status = $null

    if ($_.Exception.Response) {
        $status = [int]$_.Exception.Response.StatusCode
    }

    if ($status -eq 401) {
        Write-Host ""
        Write-Host "401 Unauthorized: username '$username' already exists"
        Write-Host "and the password does not match."
    }
    elseif ($status -eq 409) {
        Write-Host ""
        Write-Host "409 Conflict: username '$username' is already registered."
    }
    elseif ($status -eq 403) {
        Write-Host ""
        Write-Host "403 Forbidden: registration is rejected."
        Write-Host "Check 'auth.htpasswd.max_users' in config.yaml"
        Write-Host "(-1 disables registration)."
    }
    else {
        Write-Host ""
        Write-Host $_.Exception.Message
    }

    exit 1
}

# Registration also logs you in: write the token to .npmrc,
# same as npm adduser does.
if ($token) {
    $npmrc   = Join-Path $env:USERPROFILE ".npmrc"
    $authKey = "//" + ($registry -replace '^https?://', '') + "/"

    $lines = @()
    if (Test-Path $npmrc) {
        # @(pipeline) 强制数组:单行文件时 Get-Content 返回标量,
        # 若不加 @() 则下面的 += 会变成字符串拼接,把 token 粘到上一行
        $lines = @(Get-Content $npmrc -ErrorAction SilentlyContinue |
            Where-Object { $_ -notmatch ("^" + [regex]::Escape($authKey) + ":_authToken=") })
    }

    $lines += $authKey + ":_authToken=" + $token

    try {
        Set-Content -Path $npmrc -Value $lines -Encoding ASCII
        Write-Host ""
        Write-Host "Auth token written to:"
        Write-Host "  $npmrc"
    }
    catch {
        Write-Host ""
        Write-Host "WARN: could not write .npmrc ($($_.Exception.Message))."
        Write-Host "Run login to get a token."
    }
}
else {
    Write-Host ""
    Write-Host "No token returned by the registry."
    Write-Host "Run login to get a token."
}

Write-Host ""
Write-Host "========================================"
Write-Host " Register completed"
Write-Host "========================================"
Write-Host ""
Write-Host "You can test it with:"
Write-Host ""
Write-Host "  npm --registry $registry whoami"
Write-Host ""
