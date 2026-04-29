@echo off
setlocal
:: Set Local Proxy Port (v2rayN: 10808, Clash: 7890)
set PROXY_PORT=10808

echo ==========================================
echo    🚀 GitHub Fast Push Tool (Proxy Mode)
echo ==========================================

:: Inject Proxy Settings
set HTTP_PROXY=http://127.0.0.1:%PROXY_PORT%
set HTTPS_PROXY=http://127.0.0.1:%PROXY_PORT%
echo [INFO] Using Proxy: http://127.0.0.1:%PROXY_PORT%
echo ------------------------------------------

:: Check Git Status
git status -s
echo.

:: Get Commit Message
set /p COMMIT_MSG="Enter commit message (Default: 'update'): "
if "%COMMIT_MSG%"=="" set COMMIT_MSG=update

:: Git Execution
echo [1/3] Adding files...
git add .
echo [2/3] Committing changes...
git commit -m "%COMMIT_MSG%"
echo [3/3] Pushing to GitHub...
git push

echo.
echo [DONE] Repository synced successfully!
echo ==========================================
pause