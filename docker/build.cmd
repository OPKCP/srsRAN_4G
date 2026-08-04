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
IF NOT DEFINED BASE_TAG   SET BASE_TAG=base-amd64

REM Тег берётся из первого аргумента; если не задан — используется "latest"
SET TAG=%~1
IF "%TAG%"=="" SET TAG=latest

SET IMAGE=%REGISTRY%/%OWNER%/%REPO_PATH%/%REPO%:%TAG%
SET BASE_IMAGE=%REGISTRY%/%OWNER%/%REPO_PATH%/%BASE_REPO%:%BASE_TAG%

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
echo   srsRAN_4G Docker сборка
echo ==============================================
echo   Образ     : %IMAGE%
echo   База      : %BASE_IMAGE%
echo   Контекст  : %REPO_ROOT%
echo   Dockerfile: %SCRIPT_DIR%Dockerfile
echo ==============================================
echo.

docker image inspect "%BASE_IMAGE%" >nul 2>nul
IF ERRORLEVEL 1 (
    echo [INFO] Базовый образ не найден. Запускаем предварительную сборку.
    call "%SCRIPT_DIR%build-base.cmd" %BASE_TAG%
    IF ERRORLEVEL 1 (
        echo.
        echo ** ОШИБКА: Предварительная сборка базового образа завершилась с ошибкой. Код: !ERRORLEVEL!
        exit /b !ERRORLEVEL!
    )
)

REM --------------------------------------------------------------------------
REM Сборка образа. Контекст — корень репозитория, Dockerfile — в папке docker\
REM --------------------------------------------------------------------------
REM Важно: кавычки НЕ ставятся вокруг значений --build-arg, иначе Docker
REM получит значение с кавычками как часть строки (GIT_BRANCH="main").
docker build ^
    --file "%SCRIPT_DIR%Dockerfile" ^
    --build-arg "GIT_BRANCH=%GIT_BRANCH%" ^
    --build-arg "GIT_COMMIT_HASH=%GIT_COMMIT_HASH%" ^
    --build-arg "BASE_IMAGE=%BASE_IMAGE%" ^
    --tag  "%IMAGE%" ^
    --progress=plain ^
    "%REPO_ROOT%"

REM --------------------------------------------------------------------------
REM Проверяем код возврата docker build
REM --------------------------------------------------------------------------
IF ERRORLEVEL 1 (
    echo.
    echo ** ОШИБКА: Сборка завершилась с ошибкой. Код: !ERRORLEVEL!
    exit /b !ERRORLEVEL!
)

echo.
echo ** Образ успешно собран: %IMAGE%
IF NOT EXIST "%IMAGES_DIR%" mkdir "%IMAGES_DIR%"
SET IMAGE_TAR=%IMAGES_DIR%\%REPO%_%TAG%.tar
docker save -o "%IMAGE_TAR%" "%IMAGE%"
IF ERRORLEVEL 1 (
    echo.
    echo ** ОШИБКА: Экспорт образа в tar завершился с ошибкой. Код: !ERRORLEVEL!
    exit /b !ERRORLEVEL!
)
echo ** Образ экспортирован: %IMAGE_TAR%
echo.
echo Запуск eNodeB:
echo   docker compose -f docker\docker-compose.yml up -d enb
echo.
echo Запуск ядра сети EPC:
echo   docker compose -f docker\docker-compose.yml up -d epc
echo.

endlocal
