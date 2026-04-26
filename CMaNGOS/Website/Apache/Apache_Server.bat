@ECHO OFF
mode con: cols=48 lines=5
SET NAME=Apache Server
TITLE %NAME%

echo.
echo  Stop server by pressing "CTRL + C"
echo.

"%CD%\bin\httpd.exe" -d "%CD%"

exit