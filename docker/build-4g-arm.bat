@echo off
chcp 65001 >nul
REM ==============================================================================
REM docker\build-4g-arm.bat
REM Сборка Docker образа srsRAN_4G (включая srs4g) для ARM64 (RPi5).
REM
REM Использование:
REM   docker\build-4g-arm.bat [ТЕГ]
REM
REM Примеры:
REM   docker\build-4g-arm.bat           — сборка с тегом ARM
REM   docker\build-4g-arm.bat v2.0.0    — сборка с конкретной версией
REM
REM Переменные окружения:
REM   REGISTRY — реестр образов (по умолчанию ghcr.io)
REM   OWNER    — владелец репозитория (по умолчанию opkcp)
REM   REPO     — имя репозитория (по умолчанию srsran_4g)
REM   PUSH     — если "true", отправить образ в реестр после сборки
REM
REM Требования:
REM   - Docker Desktop с buildx (WSL2 backend рекомендуется)
REM   - ARM64 buildx builder:
REM       docker buildx create --name arm64-builder --use
REM       docker buildx inspect --bootstrap
REM ==============================================================================
setlocal EnableDelayedExpansion

REM --- Параметры ---
IF NOT DEFINED REGISTRY SET REGISTRY=ghcr.io
IF NOT DEFINED OWNER    SET OWNER=opkcp
IF NOT DEFINED REPO_PATH SET REPO_PATH=srsran_4g
IF NOT DEFINED REPO     SET REPO=srsran_4g
IF NOT DEFINED BASE_REPO SET BASE_REPO=%REPO%-base
IF NOT DEFINED PUSH     SET PUSH=false
IF NOT DEFINED BASE_TAG SET BASE_TAG=base-arm64

SET TAG=%~1
IF "%TAG%"=="" SET TAG=ARM
SET IMAGE=%REGISTRY%/%OWNER%/%REPO_PATH%/%REPO%:%TAG%
SET BASE_IMAGE=%REGISTRY%/%OWNER%/%REPO_PATH%/%BASE_REPO%:%BASE_TAG%

REM --- Пути ---
SET SCRIPT_DIR=%~dp0
SET REPO_ROOT=%SCRIPT_DIR%..
SET IMAGES_DIR=%SCRIPT_DIR%imgs
SET CACHE_DIR=%SCRIPT_DIR%.buildx-cache-arm64
SET CACHE_DIR_NEW=%SCRIPT_DIR%.buildx-cache-arm64-new

REM --- Git информация ---
FOR /F "tokens=*" %%B IN ('git -C "%REPO_ROOT%" rev-parse --abbrev-ref HEAD 2^>nul') DO SET GIT_BRANCH=%%B
IF NOT DEFINED GIT_BRANCH SET GIT_BRANCH=unknown

FOR /F "tokens=*" %%C IN ('git -C "%REPO_ROOT%" log -1 --format=%%h 2^>nul') DO SET GIT_COMMIT_HASH=%%C
IF NOT DEFINED GIT_COMMIT_HASH SET GIT_COMMIT_HASH=unknown

echo ==============================================
echo   srsRAN_4G ARM64 Docker сборка (с srs4g)
echo ==============================================
echo   Образ:       %IMAGE%
echo   База:        %BASE_IMAGE%
echo   Платформа:   linux/arm64
echo   Ветка:       %GIT_BRANCH%
echo   Коммит:      %GIT_COMMIT_HASH%
echo   Push:        %PUSH%
echo   Кэш buildx:  %CACHE_DIR%
echo ==============================================
echo.
echo Включённые бинарники:
echo   srsenb   — базовая станция LTE
echo   srs4g — автономный 4G модуль
echo.

IF "%PUSH%"=="true" (
    SET PUSH_ARG=--push
) ELSE (
    SET PUSH_ARG=--load
)

docker buildx build ^
    --file "%SCRIPT_DIR%Dockerfile" ^
    --platform linux/arm64 ^
    --cache-from type=local,src="%CACHE_DIR%" ^
    --cache-to type=local,dest="%CACHE_DIR_NEW%",mode=max ^
    --build-arg GIT_BRANCH=%GIT_BRANCH% ^
    --build-arg GIT_COMMIT_HASH=%GIT_COMMIT_HASH% ^
    --build-arg BASE_IMAGE=%BASE_IMAGE% ^
    --tag "%IMAGE%" ^
    %PUSH_ARG% ^
    "%REPO_ROOT%"

IF %ERRORLEVEL% NEQ 0 (
    echo.
    echo ** ОШИБКА: Сборка завершилась с кодом %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

IF EXIST "%CACHE_DIR%" rmdir /S /Q "%CACHE_DIR%"
IF EXIST "%CACHE_DIR_NEW%" ren "%CACHE_DIR_NEW%" ".buildx-cache-arm64"

echo.
echo [OK] Образ ARM64 собран: %IMAGE%
IF "%PUSH%"=="true" (
    docker pull "%IMAGE%"
    IF ERRORLEVEL 1 (
        echo.
        echo ** ОШИБКА: Не удалось загрузить образ после push. Код: !ERRORLEVEL!
        exit /b !ERRORLEVEL!
    )
)
IF NOT EXIST "%IMAGES_DIR%" mkdir "%IMAGES_DIR%"
SET IMAGE_TAR=%IMAGES_DIR%\%REPO%_%TAG%.tar
docker save -o "%IMAGE_TAR%" "%IMAGE%"
IF ERRORLEVEL 1 (
    echo.
    echo ** ОШИБКА: Экспорт ARM64 образа в tar завершился с кодом !ERRORLEVEL!
    exit /b !ERRORLEVEL!
)
echo [OK] Образ ARM64 экспортирован: %IMAGE_TAR%
IF "%PUSH%"=="true" echo [OK] Образ отправлен в реестр.
echo.

endlocal
