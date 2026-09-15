#!/usr/bin/env bash
# =============================================================================
# start-webui.sh — запуск Open5GS WebUI (Node/Next) в контейнере.
#
# Делает три вещи:
#   1) ждёт, пока MongoDB примет подключения (WebUI без БД не стартует);
#   2) идемпотентно создаёт учётную запись admin (по умолчанию admin/1423),
#      если её ещё нет — в production-режиме Open5GS WebUI НЕ создаёт её сам
#      (авто-создание есть только в dev, см. webui/server/index.js);
#   3) запускает production-сервер (node server/index.js).
#
# Переменные окружения:
#   DB_URI           — строка подключения к Mongo (по умолчанию mongodb://127.0.0.1/open5gs)
#   HOSTNAME         — адрес прослушивания (по умолчанию 0.0.0.0)
#   PORT             — порт (по умолчанию 9999)
#   WEBUI_ADMIN_USER — логин админа (по умолчанию admin)
#   WEBUI_ADMIN_PASS — пароль админа (по умолчанию 1423)
# =============================================================================
set -euo pipefail

APP_DIR="${WEBUI_APP_DIR:-/opt/open5gs/webui}"
DB_URI="${DB_URI:-mongodb://127.0.0.1/open5gs}"
export HOSTNAME="${HOSTNAME:-0.0.0.0}"
export PORT="${PORT:-9999}"
export NODE_ENV=production
# JWT/сессионный секрет (можно переопределить снаружи; иначе случайный на запуск).
export JWT_SECRET_KEY="${JWT_SECRET_KEY:-$(head -c 32 /dev/urandom | base64)}"

cd "$APP_DIR"

# --- 1. Ожидание MongoDB ---
echo "[webui] ждём MongoDB: $DB_URI"
node -e '
const mongoose=require("mongoose");
const uri=process.env.DB_URI;
const deadline=Date.now()+60000;
(function tryConnect(){
  mongoose.connect(uri,{useNewUrlParser:true,useUnifiedTopology:true,serverSelectionTimeoutMS:2000})
    .then(()=>{console.log("[webui] MongoDB доступна");process.exit(0);})
    .catch(e=>{
      if(Date.now()>deadline){console.error("[webui] MongoDB недоступна:",e.message);process.exit(1);}
      setTimeout(tryConnect,2000);
    });
})();
'

# --- 2. Идемпотентный seed админа ---
node -e '
const mongoose=require("mongoose");
const {Schema}=mongoose;
const passportLocalMongoose=require("passport-local-mongoose");
const uri=process.env.DB_URI;
const user=process.env.WEBUI_ADMIN_USER||"admin";
const pass=process.env.WEBUI_ADMIN_PASS||"1423";
const Account=new Schema({roles:[String]});
Account.plugin(passportLocalMongoose);
const M=mongoose.model("Account",Account);
(async()=>{
  try{
    await mongoose.connect(uri,{useNewUrlParser:true,useUnifiedTopology:true});
    const existing=await M.findOne({username:user});
    if(existing){console.log("[webui] админ уже есть:",user);}
    else{
      const acc=new M({username:user,roles:["admin"]});
      await M.register(acc,pass);
      console.log("[webui] создан админ:",user);
    }
    await mongoose.disconnect();
    process.exit(0);
  }catch(e){console.error("[webui] seed ошибка:",e.message);process.exit(1);}
})();
'

# --- 3. Запуск сервера ---
echo "[webui] старт на http://${HOSTNAME}:${PORT}"
exec node server/index.js
