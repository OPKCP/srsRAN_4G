@echo off
chcp 65001 >nul
REM ==============================================================================
REM Скрипт локальной сборки Docker образа srsRAN_4G для Windows 11 (CMD)
REM
REM Использование:
REM   docker\build.cmd [ТЕГ]
REM
REM Примеры:
REM   docker\build.cmd              -- сборка с тегом latest
REM   docker\build.cmd v1.0.0       -- сборка с конкретной версией
REM   docker\build.cmd dev          -- сборка образа для разработки
REM
REM Требования:
REM   - Docker Desktop for Windows с включённым движком Linux containers
REM   - WSL 2 (рекомендуется для производительности)
REM ==============================================================================

setlocal EnableDelayedExpansion

git pull

docker rm -f enb epc >nul 2>nul

REM --------------------------------------------------------------------------
REM Настройки образа (можно переопределить через SET перед запуском)
REM --------------------------------------------------------------------------
IF NOT DEFINED REGISTRY   SET REGISTRY=ghcr.io
IF NOT DEFINED OWNER      SET OWNER=opkcp
IF NOT DEFINED REPO_PATH  SET REPO_PATH=srsran_4g
IF NOT DEFINED REPO       SET REPO=srsran_4g
IF NOT DEFINED BASE_REPO  SET BASE_REPO=%REPO%-base
IF NOT DEFINED BASE_TAG   SET BASE_TAG=base-arm64

REM Тег берётся из первого аргумента; если не задан — используется "latest"
SET TAG=%~1
IF "%TAG%"=="" SET TAG=latest

SET IMAGE=%REGISTRY%/%OWNER%/%REPO_PATH%/%REPO%:%TAG%
SET BASE_IMAGE=%REGISTRY%/%OWNER%/%REPO_PATH%/%BASE_REPO%:%BASE_TAG%
SET IMAGEARM=%REGISTRY%/%OWNER%/%REPO_PATH%/%REPO%:ARM

FOR /F "delims=" %%i IN ('git rev-parse --abbrev-ref HEAD 2^>nul') DO SET GIT_BRANCH=%%i
FOR /F "delims=" %%i IN ('git log -1 --format=%%h 2^>nul') DO SET GIT_COMMIT_HASH=%%i
IF NOT DEFINED GIT_BRANCH SET GIT_BRANCH=unknown
IF NOT DEFINED GIT_COMMIT_HASH SET GIT_COMMIT_HASH=unknown

REM --------------------------------------------------------------------------
REM Определяем корневую директорию репозитория (на уровень выше docker\)
REM --------------------------------------------------------------------------
SET SCRIPT_DIR=%~dp0
SET REPO_ROOT=%SCRIPT_DIR%..
SET IMAGES_DIR=%SCRIPT_DIR%imgs

echo ==============================================
echo   srsRAN_4G Docker сборка arm64
echo ==============================================
echo   Образ     : %IMAGEARM%
echo   База      : %BASE_IMAGE%
echo   Контекст  : %REPO_ROOT%
echo   Dockerfile: %SCRIPT_DIR%Dockerfile
echo ==============================================
echo.

docker image inspect "%BASE_IMAGE%" >nul 2>nul
IF ERRORLEVEL 1 (
    echo [INFO] Базовый образ не найден. Запускаем предварительную сборку.
    call "%SCRIPT_DIR%build-base-arm.cmd" %BASE_TAG%
    IF ERRORLEVEL 1 (
        echo.
        echo ** ОШИБКА: Предварительная сборка базового образа завершилась с ошибкой. Код: !ERRORLEVEL!
        exit /b !ERRORLEVEL!
    )
)
	
docker build ^
    --file "%SCRIPT_DIR%Dockerfile" ^
	--platform linux/arm64 ^
    --build-arg GIT_BRANCH="%GIT_BRANCH%" ^
    --build-arg GIT_COMMIT_HASH="%GIT_COMMIT_HASH%" ^
    --build-arg BASE_IMAGE="%BASE_IMAGE%" ^
    --tag  "%IMAGEARM%" ^
    "%REPO_ROOT%"

REM --------------------------------------------------------------------------
REM Проверяем код возврата docker build
REM --------------------------------------------------------------------------
IF ERRORLEVEL 1 (
    echo.
    echo ** ОШИБКА: Сборка завершилась с ошибкой. Код: !ERRORLEVEL!
    exit /b !ERRORLEVEL!
)

IF NOT EXIST "%IMAGES_DIR%" mkdir "%IMAGES_DIR%"
SET IMAGE_TAR=%IMAGES_DIR%\%REPO%_ARM.tar
docker save -o "%IMAGE_TAR%" "%IMAGEARM%"
IF ERRORLEVEL 1 (
    echo.
    echo ** ОШИБКА: Экспорт ARM образа в tar завершился с ошибкой. Код: !ERRORLEVEL!
    exit /b !ERRORLEVEL!
)
echo [OK] Образ ARM64 экспортирован: %IMAGE_TAR%

endlocal
