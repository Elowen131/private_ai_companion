@echo off
rem 本地测试运行器（Windows 入口，委托给 Git Bash 执行 run_tests.sh）。
rem 用法同 run_tests.sh：
rem   run_tests.bat                 （纯用例）
rem   run_tests.bat --coverage
rem   run_tests.bat test\foo_test.dart
rem   run_tests.bat all
bash "%~dp0run_tests.sh" %*
