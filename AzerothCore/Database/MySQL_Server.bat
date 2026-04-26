@echo off
mode con: cols=48 lines=5
SET NAME=MySQL Server
TITLE %NAME%

echo.
echo  Stop server by pressing "CTRL + C"
echo.

"%CD%\bin\mysqld" --defaults-file="%CD%\config.ini" --standalone --explicit_defaults_for_timestamp --sql-mode="" --log_error_verbosity=2 --datadir="%CD%\data"

exit
