@echo off
setlocal
cd /d "%~dp0"
where node >nul 2>nul || (echo Node.js 18+ is required: https://nodejs.org/en/download & pause & exit /b 1)
if not exist node_modules call npm install || exit /b 1
if not exist dist call npm run build || exit /b 1
start "" http://127.0.0.1:5050
call npm start
