@echo off
mode con: cols=43 lines=16
SET NAME=Database Server
TITLE %NAME%
COLOR 0A

echo.
echo      ---------- MySQL Info -----------
echo.
echo  Included:
echo   .MySQL Community Server 5.7.29
echo.
echo  Database access:
echo   .User: spp_user
echo   .Pass: 123456
echo   .Port: 3310
echo.
echo  Stop server by pressing "CTRL + C"

"%CD%\bin\mysqld" --defaults-file="%CD%\SPP-Database.ini" --console --standalone --log_syslog=0 --explicit_defaults_for_timestamp --sql-mode="" --log_error_verbosity=1

exit
