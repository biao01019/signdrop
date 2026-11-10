# 把工程推到 GitHub，让 Actions 编出未签名 IPA。
#
# 用法（在项目根目录）：
#   powershell -ExecutionPolicy Bypass -File scripts\push-to-github.ps1 -RepoUrl https://github.com/你的账号/signdrop.git
#
# 前提：先在 github.com/new 建一个空仓库（不要勾 README / .gitignore 模板），
#       本机装好 git（已装好）和 PowerShell。

param(
    [Parameter(Mandatory = $true)]
    [string]$RepoUrl,

    [string]$Message = "build: first CI build"
)

$ErrorActionPreference = "Stop"

function Say($text) { Write-Host "==> $text" -ForegroundColor Cyan }

# 1. 检查 git
if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    throw "找不到 git，请先安装：https://git-scm.com/download/win"
}

if ($RepoUrl -notmatch '^https://github\.com/(?<owner>[^/]+)/(?<repo>[^/]+?)(\.git)?$') {
    throw "RepoUrl 格式应为 https://github.com/<账号>/<仓库>.git"
}
$owner = $Matches['owner']
$repo = $Matches['repo']

# 2. 初始化仓库
if (-not (Test-Path ".git")) {
    Say "初始化 git 仓库"
    git init | Out-Host
    git branch -M main | Out-Host
}

# 3. 提交
Say "提交代码"
git add -A | Out-Host
$pending = git status --porcelain
if ($pending) {
    git commit -m $Message | Out-Host
} else {
    Say "没有新改动，跳过提交"
}

# 4. 设置远端
$existing = git remote 2>$null
if ($existing -match "origin") {
    git remote set-url origin $RepoUrl | Out-Host
} else {
    git remote add origin $RepoUrl | Out-Host
}

# 5. 推送（第一次会弹浏览器让你登录 GitHub）
Say "推送到 $RepoUrl"
git push -u origin main
if ($LASTEXITCODE -ne 0) {
    throw "推送失败。确认仓库已建好且为空；如果提示认证失败，重跑一次并完成浏览器登录。"
}

$base = "https://github.com/$owner/$repo"
Write-Host ""
Write-Host "推送成功。" -ForegroundColor Green
Write-Host "  看编译进度: $base/actions"
Write-Host "  下载 IPA    : $base/releases/download/latest/SignKit-unsigned.ipa"
Write-Host ""
Write-Host "首次编译约 4 分钟。若失败，下载该次运行的 build-log 产物，那是 Swift 编译错误，改完再跑一次本脚本。"
Write-Host "装到手机的后续步骤见 docs/install-ios.md 的 A3 节。"
