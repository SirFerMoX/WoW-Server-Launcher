@ECHO OFF
mode con: cols=43 lines=16
SET NAME=Website Server
TITLE %NAME%
COLOR 0A

echo.
echo      -------- Website Server ---------
echo.
echo.
echo  Included:
echo   .Apache 2.4.25
echo   .PHP 7.2.26
echo.
echo  Website access: http://127.0.0.1
echo.
echo  Stop server by pressing "CTRL + C"
echo.

"%CD%\bin\spp-httpd.exe" -d "%CD%"

exit