local ffi = assert(modules.corelib.require, "require no disponible")("ffi")
assert(ffi.os=="Windows","Koofr nativo requiere Windows con FFI")
local owner=modules.game_bot
if owner.customBotNativeKoofr then owner.customBotNativeKoofr.close() end
local D={}
local providers={
  koofr={name="koofr",host="app.koofr.net",root="/dav/Koofr",directory="/CustomBot_Koofr",file="cuenta.bin"}
}
local providerKey="koofr"
local provider=providers[providerKey]
dofile("/koofr_dav.lua")
local dav=assert(CustomPanelKoofrDAV,"No se pudo cargar WebDAV").create(provider)
local crypt=ffi.load("crypt32")
local kernel=ffi.load("kernel32")
if not owner.customBotCloudCredentialsCdef then
ffi.cdef[[
typedef struct { unsigned long size; unsigned char *data; } CB_BLOB;
void * __stdcall LocalFree(void*);
int __stdcall CryptProtectData(CB_BLOB*,const uint16_t*,CB_BLOB*,void*,void*,unsigned long,CB_BLOB*);
int __stdcall CryptUnprotectData(CB_BLOB*,uint16_t**,CB_BLOB*,void*,void*,unsigned long,CB_BLOB*);
]]
owner.customBotCloudCredentialsCdef=true
end

local resources=g_resources
local directory=provider.directory
local tokenFile=directory.."/"..provider.file
local function protect(data,decrypt)
  local input=ffi.new("CB_BLOB")
  local buffer=ffi.new("unsigned char[?]",#data+1)
  ffi.copy(buffer,data,#data)
  input.size=#data;input.data=buffer
  local output=ffi.new("CB_BLOB")
  local ok
  if decrypt then ok=crypt.CryptUnprotectData(input,nil,nil,nil,nil,1,output)
  else ok=crypt.CryptProtectData(input,nil,nil,nil,nil,1,output) end
  assert(ok~=0,"No se pudo acceder a la autorizacion de Windows. Vuelve a conectar.")
  local result=ffi.string(output.data,output.size)
  kernel.LocalFree(output.data)
  return result
end
local function persist(t)
  if not resources.directoryExists(directory) then resources.makeDir(directory) end
  local value=protect(json.encode(t),false)
  assert(resources.writeFileContents(tokenFile,value)~=false and resources.readFileContents(tokenFile)==value,
         "No se pudo guardar la autorizacion")
end
if not CustomPanelHTTP then dofile("/httpLib.lua") end
local http=assert(CustomPanelHTTP,"No se pudo cargar el transporte HTTP")
-- OTC C++ bindings must always be called on its main Lua state.
-- Continuations are dispatched by the integrated HTTP transport through the OTC event loop.
local running
function D.run(task,done,progress)
  assert(not running,"Ya hay una operacion de nube en curso")
  local job={done=done,progress=progress}
  running=job
  function job.finish(ok,result)
    if running~=job then return end
    running=nil
    job.done(ok,result)
  end
  function job.call(fn,...)
    if running~=job then return end
    local ok,err=pcall(fn,...)
    if not ok then job.finish(false,tostring(err)) end
  end
  job.call(task,job.finish)
end
local function request(method,url,body,contentType,authorization,depth,accepted,callback)
  local job=assert(running,"Operacion de nube fuera de una tarea")
  job.pending=http.start(method,url,body,contentType,authorization,depth,function(ok,data,status)
    job.pending=nil
    if running~=job then return end
    if not ok then job.finish(false,data) return end
    if not (accepted and accepted[status]) and not (status>=200 and status<300) then
      local message={
        [401]="Correo o contrasena de aplicacion de koofr incorrectos.",
        [403]="La nube no permite esta operacion.",
        [404]="No existe esa carpeta o archivo en la nube.",
        [409]="Falta una carpeta intermedia en la nube.",
        [429]="La nube limita las solicitudes. Espera antes de volver a intentar.",
        [507]="No queda espacio suficiente en la nube."
      }
      job.finish(false,message[status] or (provider.name.." devolvio HTTP "..tostring(status)))
      return
    end
    job.call(callback,data,status)
  end,job.progress)
end
local credentials
local function account()
  if not credentials then
    assert(resources.fileExists(tokenFile),"Conecta tu cuenta de "..provider.name.." primero.")
    local ok,result=pcall(function()
      return json.decode(protect(resources.readFileContents(tokenFile),true))
    end)
    assert(ok and type(result)=="table","Vuelve a conectar "..provider.name.." en este Windows.")
    credentials=result
  end
  assert(type(credentials.user)=="string" and type(credentials.password)=="string","Vuelve a conectar "..provider.name..".")
  return dav.basic(credentials.user,credentials.password)
end
function D.selectProvider(key)
  assert(not running,"Espera a que termine la transferencia antes de cambiar de nube")
  local selected=assert(providers[key],"Proveedor de nube invalido")
  if key~=providerKey then
    providerKey=key
    provider=selected
    dav=CustomPanelKoofrDAV.create(provider)
    directory=provider.directory
    tokenFile=directory.."/"..provider.file
    credentials=nil
  end
end
function D.providerName() return provider.name end
local propfind='<?xml version="1.0" encoding="utf-8"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/><d:getcontentlength/></d:prop></d:propfind>'
function D.cancel()
  local job=running
  if job and job.pending then job.pending.cancel(true) end
end
function D.close()
  local job=running
  running=nil
  if job and job.pending then job.pending.cancel(false) end
  credentials=nil
end
function D.connect(user,password,done)
  user=user:match("^%s*(.-)%s*$")
  assert(user~="" and not user:find("[:%c]") and user:find("@",1,true),"Escribe tu correo de "..provider.name..".")
  assert(type(password)=="string" and #password>0 and not password:find("[%c]"),"Escribe la contrasena de aplicacion WebDAV de koofr.")
  request("PROPFIND",dav.url("/"),propfind,"application/xml; charset=utf-8",dav.basic(user,password),"0",nil,function()
    local value={user=user,password=password}
    persist(value)
    credentials=value
    done("Cuenta de "..provider.name.." conectada.")
  end)
end
function D.list(folder,done)
  folder=dav.path(folder)
  request("PROPFIND",dav.url(folder)..(folder=="/" and "" or "/"),
    propfind,"application/xml; charset=utf-8",account(),"1",nil,function(data)
      done(dav.parse(data,folder))
    end)
end
local function ensureFolder(folder,done)
  local paths,path={},""
  for part in dav.path(folder):gmatch("[^/]+") do
    path=path.."/"..part
    paths[#paths+1]=dav.url(path).."/"
  end
  local auth=account()
  local index=0
  local function nextFolder()
    index=index+1
    if index>#paths then done() return end
    local url=paths[index]
    request("PROPFIND",url,propfind,"application/xml; charset=utf-8",auth,"0",{[404]=true},function(data,status)
      if status==404 then
        request("MKCOL",url,nil,nil,auth,nil,{[405]=true},function(_,created)
          if created==405 then
            request("PROPFIND",url,propfind,"application/xml; charset=utf-8",auth,"0",nil,function(existing)
              assert(existing:find("<[%w_%-]*:?collection[%s/>]"),"La ruta remota es un archivo.")
              nextFolder()
            end)
          else nextFolder() end
        end)
      else
        assert(data:find("<[%w_%-]*:?collection[%s/>]"),"Una parte de la ruta es un archivo.")
        nextFolder()
      end
    end)
  end
  nextFolder()
end
function D.upload(folder,name,bytes,done)
  assert(type(bytes)=="string" and #bytes>0,"ZIP vacio")
  local remote=dav.join(folder,name)
  ensureFolder(folder,function()
    request("PUT",dav.url(remote),bytes,"application/zip",account(),nil,nil,function() done() end)
  end)
end
function D.download(path,done)
  path=dav.path(path)
  assert(path:lower():match("%.zip$"),"Selecciona un ZIP compatible.")
  request("GET",dav.url(path),nil,nil,account(),nil,nil,function(data) done(data) end)
end
D.path=dav.path
owner.customBotNativeKoofr=D
CustomPanelKoofr=D
