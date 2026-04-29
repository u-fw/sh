@echo off
:: 设置字符集为 UTF-8 防止中文乱码
chcp 65001 >nul
echo ==========================================
echo    🚀 GitHub 极速一键推送脚本 (带代理)
echo ==========================================

:: 【关键】修改为你的客户端代理端口！
:: v2rayN 默认是 10808，NekoBox 默认是 2080 / 2081，Clash 默认 7890
set PROXY_PORT=10808

set HTTP_PROXY=http://127.0.0.1:%PROXY_PORT%
set HTTPS_PROXY=http://127.0.0.1:%PROXY_PORT%
echo 🌐 已临时挂载本地代理: http://127.0.0.1:%PROXY_PORT%
echo ------------------------------------------

:: 检查本地文件变动
git status -s
echo.

:: 交互式输入提交说明
set /p MSG="📝 请输入提交说明 (直接回车默认为 'Auto update'): "
if "%MSG%"=="" set MSG=Auto update

:: 执行 Git 三步曲
echo.
echo 📦 正在打包暂存区...
git add .
git commit -m "%MSG%"

echo 🚀 正在通过代理全速推送到 GitHub...
git push

echo.
echo ✅ 同步彻底完成！
echo ==========================================
pause