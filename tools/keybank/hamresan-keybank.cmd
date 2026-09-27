@echo off
rem Hamresan key-bank tool. Keep this file next to hamresan-keybank.jar.
chcp 65001 >nul
java -Dstdout.encoding=UTF-8 -Dstderr.encoding=UTF-8 -jar "%~dp0hamresan-keybank.jar" %*
