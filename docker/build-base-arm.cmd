@echo off
chcp 65001 >nul
REM ==============================================================================
REM Скрипт предварительной сборки базового Docker образа srsRAN_4G для ARM64 (CMD)
REM ==============================================================================

setlocal EnableDelayedExpansion

IF NOT DEFINED REGISTRY   SET REGISTRY=ghcr.io
IF NOT DEFINED OWNER      SET OWNER=opkcp
IF NOT DEFINED REPO_PATH  SET REPO_PATH=srsran_4g
IF NOT DEFINED REPO       SET REPO=srsran_4g
IF NOT DEFINED BASE_REPO  SET BASE_REPO=%REPO%-base

SET BASE_TAG=%~1
IF "%BASE_TAG%"=="" SET BASE_TAG=base-arm64

SET BASE_IMAGE=%REGISTRY%/%OWNER%/%REPO_PATH%/%BASE_REPO%:%BASE_TAG%

FOR /F "delims=" %%i IN ('git rev-parse --abbrev-ref HEAD 2^>nul') DO SET GIT_BRANCH=%%i
FOR /F "delims=" %%i IN ('git log -1 --format=%%h 2^>nul') DO SET GIT_COMMIT_HASH=%%i
IF NOT DEFINED GIT_BRANCH SET GIT_BRANCH=unknown
IF NOT DEFINED GIT_COMMIT_HASH SET GIT_COMMIT_HASH=unknown

SET SCRIPT_DIR=%~dp0
SET REPO_ROOT=%SCRIPT_DIR%..
SET IMAGES_DIR=%SCRIPT_DIR%imgs

echo ==============================================
echo   srsRAN_4G базовый Docker образ arm64
echo ==============================================
echo   Образ     : %BASE_IMAGE%
echo   Платформа : linux/arm64
echo ==============================================
echo.

docker buildx build ^
    --platform linux/arm64 ^
    --pull ^
    --file "%SCRIPT_DIR%Dockerfile.base" ^
    --build-arg GIT_BRANCH="%GIT_BRANCH%" ^
    --build-arg GIT_COMMIT_HASH="%GIT_COMMIT_HASH%" ^
    --tag "%BASE_IMAGE%" ^
    --load ^
    "%REPO_ROOT%"

IF %ERRORLEVEL% NEQ 0 (
    echo.
    echo ** ОШИБКА: Предварительная сборка базового образа завершилась с ошибкой. Код: %ERRORLEVEL%
    exit /b %ERRORLEVEL%
)

echo.
echo ** Базовый образ arm64 успешно собран: %BASE_IMAGE%
IF NOT EXIST "%IMAGES_DIR%" mkdir "%IMAGES_DIR%"
SET IMAGE_TAR=%IMAGES_DIR%\%BASE_REPO%_%BASE_TAG%.tar
docker save -o "%IMAGE_TAR%" "%BASE_IMAGE%"
IF ERRORLEVEL 1 (
    echo.
    echo ** ОШИБКА: Экспорт базового образа arm64 в tar завершился с ошибкой. Код: !ERRORLEVEL!
    exit /b !ERRORLEVEL!
)
echo ** Базовый образ arm64 экспортирован: %IMAGE_TAR%
echo.

endlocal
