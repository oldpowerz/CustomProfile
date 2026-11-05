local ffi = assert(modules.corelib.require, "require no disponible")("ffi")
assert(ffi.os=="Windows","Koofr nativo requiere Windows con FFI")
local owner=modules.game_bot
if owner.customBotNativeKoofr then owner.customBotNativeKoofr.close() end
local D={}
-- Utilidades WebDAV integradas.
local dav
do
-- Utilidades WebDAV independientes del transporte de Windows.
local M = {}
function M.path(path)
  assert(type(path)=="string" and #path<=1500,"Ruta de Koofr invalida")
  path="/"..path:gsub("^/+",""):gsub("/+$","")
  assert(not path:find("[%c\\?#]") and not path:find("//",1,true),"Ruta de Koofr invalida")
  for part in path:gmatch("[^/]+") do assert(part~="." and part~="..","Ruta de Koofr invalida") end
  return path
end
function M.escape(s)
  return (s:gsub("([^%w%-_%.~])",function(c)return string.format("%%%02X",c:byte())end))
end
function M.url(path)
  path=M.path(path)
  local parts={}
  for p in path:gmatch("[^/]+")do parts[#parts+1]=M.escape(p) end
  return "https://app.koofr.net/dav/Koofr/"..table.concat(parts,"/")
end
function M.join(folder,name)
  assert(type(name)=="string" and #name>0 and not name:find("[/%c\\?#]") and name~="." and name~="..","Nombre remoto invalido")
  return M.path(folder.."/"..name)
end
local alphabet="ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
function M.basic(user,password)
  local data=user..":"..password
  local out={}
  for i=1,#data,3 do
    local a,b,c=data:byte(i,i+2)
    local n=a*65536+(b or 0)*256+(c or 0)
    for j=1,4 do
      local v=math.floor(n/64^(4-j))%64+1
      out[#out+1]=(j>2 and i+j-2>#data) and "=" or alphabet:sub(v,v)
    end
  end
  return "Basic "..table.concat(out)
end
local function utf8(n)
  assert(n>=0 and n<=1114111 and not (n>=55296 and n<=57343),"Entidad XML invalida")
  if n<128 then return string.char(n) end
  if n<2048 then return string.char(192+math.floor(n/64),128+n%64) end
  if n<65536 then return string.char(224+math.floor(n/4096),128+math.floor(n/64)%64,128+n%64) end
  return string.char(240+math.floor(n/262144),128+math.floor(n/4096)%64,128+math.floor(n/64)%64,128+n%64)
end
local function xml(s)
  if s:match("^<!%[CDATA%[.*%]%]>$") then return s:sub(10,-4) end
  local entities={amp="&",lt="<",gt=">",quot='"',apos="'"}
  return (s:gsub("&([^;]+);",function(v)
    if entities[v] then return entities[v] end
    if v:match("^#x%x+$") then return utf8(tonumber(v:sub(3),16)) end
    if v:match("^#%d+$") then return utf8(tonumber(v:sub(2))) end
    error("Entidad XML desconocida")
  end))
end
function M.parse(document,folder)
  assert(type(document)=="string" and not document:find("<!DOCTYPE",1,true),"Respuesta WebDAV invalida")
  assert(document:find("<[%w_%-]*:?multistatus[%s>]"),"Koofr no devolvio una lista WebDAV")
  folder=M.path(folder)
  local prefix="/dav/Koofr"..(folder=="/" and "" or folder)
  local entries,seen={},{}
  -- WebDAV puede usar cualquier prefijo XML (d:, D:, ns0:) o ninguno.
  for block in document:gmatch("<[%w_%-]*:?response[%s>].-</[%w_%-]*:?response%s*>") do
    local raw=block:match("<[%w_%-]*:?href[^>]*>(.-)</[%w_%-]*:?href%s*>")
    local success=block:match("<[%w_%-]*:?status[^>]*>HTTP/[%d%.]+%s+200%s")
    if raw and success then
      local href=xml(raw)
      if href:match("^https://") then
        local host,rest=href:match("^https://([^/]+)(/.*)$")
        assert(host=="app.koofr.net","Servidor WebDAV inesperado")
        href=rest
      end
      href=href:gsub("%%(%x%x)",function(h)return string.char(tonumber(h,16))end):gsub("/+$","")
      if href:sub(1,#prefix+1)==prefix.."/" then
        local name=href:sub(#prefix+2)
        if name~="" and not name:find("/",1,true) then
          local path=M.join(folder,name)
          if not seen[path] then
            local isFolder=block:find("<[%w_%-]*:?collection[%s/>]")~=nil
            if isFolder or name:lower():match("%.zip$") then
              entries[#entries+1]={name=name,id=path,folder=isFolder}
              seen[path]=true
            end
          end
        end
      end
    end
  end
  table.sort(entries,function(a,b)
    if a.folder~=b.folder then return a.folder end
    return a.name:lower()<b.name:lower()
  end)
  return entries
end
CustomPanelKoofrDAV = M
  dav=M
end
local win=ffi.load("winhttp")
local crypt=ffi.load("crypt32")
local kernel=ffi.load("kernel32")
if not owner.customBotNativeKoofrCdef then
ffi.cdef[[
typedef void *CB_HANDLE;
typedef struct { unsigned long size; unsigned char *data; } CB_BLOB;
int __stdcall MultiByteToWideChar(unsigned int,unsigned long,const char*,int,uint16_t*,int);
void * __stdcall LocalFree(void*);
int __stdcall CryptProtectData(CB_BLOB*,const uint16_t*,CB_BLOB*,void*,void*,unsigned long,CB_BLOB*);
int __stdcall CryptUnprotectData(CB_BLOB*,uint16_t**,CB_BLOB*,void*,void*,unsigned long,CB_BLOB*);
CB_HANDLE __stdcall WinHttpOpen(const uint16_t*,unsigned long,const uint16_t*,const uint16_t*,unsigned long);
CB_HANDLE __stdcall WinHttpConnect(CB_HANDLE,const uint16_t*,unsigned short,unsigned long);
CB_HANDLE __stdcall WinHttpOpenRequest(CB_HANDLE,const uint16_t*,const uint16_t*,const uint16_t*,const uint16_t*,const uint16_t**,unsigned long);
int __stdcall WinHttpSetTimeouts(CB_HANDLE,int,int,int,int);
int __stdcall WinHttpSetOption(CB_HANDLE,unsigned long,void*,unsigned long);
int __stdcall WinHttpSendRequest(CB_HANDLE,const uint16_t*,unsigned long,void*,unsigned long,unsigned long,uintptr_t);
int __stdcall WinHttpReceiveResponse(CB_HANDLE,void*);
int __stdcall WinHttpQueryHeaders(CB_HANDLE,unsigned long,const uint16_t*,void*,unsigned long*,unsigned long*);
int __stdcall WinHttpReadData(CB_HANDLE,void*,unsigned long,unsigned long*);
int __stdcall WinHttpCloseHandle(CB_HANDLE);
]]
owner.customBotNativeKoofrCdef = true
end
local function wide(s)
  local n=kernel.MultiByteToWideChar(65001,0,s,#s,nil,0)
  assert(n>0,"Texto UTF-8 invalido")
  local buf=ffi.new("uint16_t[?]",n+1)
  assert(kernel.MultiByteToWideChar(65001,0,s,#s,buf,n)==n,"Fallo UTF-8")
  return buf
end

local resources=g_resources
local directory="/CustomBot_Koofr"
local tokenFile=directory.."/cuenta.bin"
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
-- Transporte WinHTTP integrado.
local http
do
-- WinHTTP asíncrono. Los hilos de Windows solo escriben seis DWORD.
-- Todo Lua, incluida la UI, se ejecuta desde el event loop de OTC.
local ffi=modules.corelib.require("ffi")
local kernel=ffi.load("kernel32")
local win=ffi.load("winhttp")
local owner=modules.game_bot
if not owner.customBotAsyncHTTPDefs then
  ffi.cdef[[
void * __stdcall VirtualAlloc(void*,size_t,unsigned long,unsigned long);
int __stdcall VirtualProtect(void*,size_t,unsigned long,unsigned long*);
int __stdcall VirtualFree(void*,size_t,unsigned long);
void * __stdcall GetCurrentProcess(void);
int __stdcall FlushInstructionCache(void*,const void*,size_t);
unsigned long __stdcall GetLastError(void);
void * __stdcall WinHttpSetStatusCallback(void*,void*,unsigned long,uintptr_t);
int __stdcall WinHttpWriteData(void*,const void*,unsigned long,unsigned long*);
]]
  owner.customBotAsyncHTTPDefs=true
end
local machine={
  x64="f30f1efa4885d2742d4181f800001000747e772c4181f80000020074634181f800000800743a4181f8000800007571c7421401000000c3660f1f8400000000004181f80000200074274181f80000400075e4c70201000000c30f1f80000000008b44242883c001894208c30f1f440000418b410883c001894210c30f1f440000c7420401000000c30f1f840000000000418b0183c00189420cc3660f1f440000c3",
  x86="8b5424088b44240c85d274253d00001000746d77233d0000020074543d00000800742d3d000800007507c7421401000000c214008d7426003d0000200074213d0000400075ebc70201000000ebe366908b44241483c001894208ebd58d7426008b4424108b400483c001894210ebc290c7420401000000ebb88db426000000008b4424108b0083c00189420ceba3"
}
local runtime=owner.customBotAsyncHTTPv1
if not runtime then
  local hex=assert(machine[ffi.arch],"Arquitectura no compatible con el transporte Koofr")
  local code=hex:gsub("..",function(h)return string.char(tonumber(h,16))end)
  local ptr=kernel.VirtualAlloc(nil,#code,0x3000,4)
  assert(ptr~=nil,"Windows no permitio preparar el transporte asincrono")
  ffi.copy(ptr,code,#code)
  local old=ffi.new("unsigned long[1]")
  if kernel.VirtualProtect(ptr,#code,0x20,old)==0 then
    kernel.VirtualFree(ptr,0,0x8000)
    error("Windows no permitio activar el transporte asincrono")
  end
  assert(kernel.FlushInstructionCache(kernel.GetCurrentProcess(),ptr,#code)~=0,"Fallo la inicializacion del transporte")
  -- El callback se conserva durante toda la vida del cliente.
  runtime={callback=ptr,retired={}}
  owner.customBotAsyncHTTPv1=runtime
end
local function later(fn) return modules.corelib.scheduleEvent(fn,20) end
local function reap()
  for i=#runtime.retired,1,-1 do
    if runtime.retired[i].state[5]~=0 then table.remove(runtime.retired,i) end
  end
  if #runtime.retired>0 then later(reap) else runtime.reaping=false end
end
local function wide(s)
  local n=kernel.MultiByteToWideChar(65001,0,s,#s,nil,0)
  assert(n>0,"Texto UTF-8 invalido")
  local p=ffi.new("uint16_t[?]",n+1)
  assert(kernel.MultiByteToWideChar(65001,0,s,#s,p,n)==n,"Fallo UTF-8")
  return p
end
local H={}
function H.start(method,url,body,contentType,authorization,depth,done,progress)
  local host,path=url:match("^https://([%w%.%-]+)(/.*)$")
  assert(host=="app.koofr.net" and path and path:sub(1,11)=="/dav/Koofr/","Destino HTTPS invalido")
  assert(not authorization:find("[%c]"),"Autorizacion invalida")
  local op={
    handles={}, state=ffi.new("volatile uint32_t[6]"),
    readBuffer=ffi.new("char[262144]"), chunks={},received=0,sent=0,
    body=body or "", phase="send", start=os.time()
  }
  local function keep(h)
    assert(h~=nil,"WinHTTP no pudo crear la conexion")
    op.handles[#op.handles+1]=h
    return h
  end
  local function close()
    for i=#op.handles,1,-1 do win.WinHttpCloseHandle(op.handles[i]) end
    op.handles={}
    if op.installed then
      runtime.retired[#runtime.retired+1]=op
      if not runtime.reaping then runtime.reaping=true;later(reap) end
    end
  end
  local function finish(ok,data,status)
    if op.finished then return end
    op.finished=true
    close()
    done(ok,data,status)
  end
  function op.cancel(notify)
    if op.finished then return end
    if notify then finish(false,"Operacion cancelada")
    else op.finished=true;close() end
  end
  local function check(result,step)
    assert(result~=0 or kernel.GetLastError()==997,
      "WinHTTP "..step.." fallo ("..tonumber(kernel.GetLastError())..")")
  end
  local function read()
    op.phase="read"
    check(win.WinHttpReadData(op.req,op.readBuffer,262144,nil),"lectura")
  end
  local function write()
    if op.sent==#op.body then
      op.phase="headers"
      check(win.WinHttpReceiveResponse(op.req,nil),"respuesta")
    else
      op.phase="write"
      op.writeSize=math.min(262144,#op.body-op.sent)
      op.writeBuffer=ffi.new("char[?]",op.writeSize)
      ffi.copy(op.writeBuffer,ffi.cast("const char*",op.body)+op.sent,op.writeSize)
      check(win.WinHttpWriteData(op.req,op.writeBuffer,op.writeSize,nil),"envio")
    end
  end
  local function poll()
    if op.finished then return end
    local ok,err=pcall(function()
      assert(os.time()-op.start<900,"Se agoto el tiempo de transferencia")
      if op.state[4]~=0 then error("WinHTTP fallo ("..(tonumber(op.state[4])-1).."). Revisa la conexion.") end
      if op.phase=="send" and op.state[0]~=0 then
        op.state[0]=0
        write()
      elseif op.phase=="write" and op.state[3]~=0 then
        local count=tonumber(op.state[3])-1
        op.state[3]=0
        assert(count>0 and count<=op.writeSize,"Envio incompleto")
        op.sent=op.sent+count
        op.writeBuffer=nil
        write()
      elseif op.phase=="headers" and op.state[1]~=0 then
        op.state[1]=0
        local code=ffi.new("unsigned long[1]")
        local size=ffi.new("unsigned long[1]",4)
        assert(win.WinHttpQueryHeaders(op.req,0x20000013,nil,code,size,nil)~=0,"Estado HTTP invalido")
        op.status=tonumber(code[0])
        size[0]=4
        if win.WinHttpQueryHeaders(op.req,0x20000005,nil,code,size,nil)~=0 then op.total=tonumber(code[0]) end
        assert(not op.total or op.total<=272*1024*1024,"Respuesta demasiado grande")
        read()
      elseif op.phase=="read" and op.state[2]~=0 then
        local count=tonumber(op.state[2])-1
        op.state[2]=0
        if count==0 then
          finish(true,table.concat(op.chunks),op.status)
          return
        end
        op.received=op.received+count
        assert(op.received<=272*1024*1024,"Respuesta demasiado grande")
        op.chunks[#op.chunks+1]=ffi.string(op.readBuffer,count)
        read()
      end
      if progress then progress(op.sent,#op.body,op.received,op.total) end
    end)
    if not ok then finish(false,tostring(err))
    elseif not op.finished then later(poll) end
  end
  local ok,err=pcall(function()
    local session=keep(win.WinHttpOpen(wide("CustomBot/Koofr"),1,nil,nil,0x10000000))
    assert(win.WinHttpSetTimeouts(session,5000,10000,30000,30000)~=0,"Fallo el timeout HTTP")
    local connection=keep(win.WinHttpConnect(session,wide(host),443,0))
    op.req=keep(win.WinHttpOpenRequest(connection,wide(method),wide(path),nil,nil,nil,0x800000))
    local policy=ffi.new("unsigned long[1]",0)
    assert(win.WinHttpSetOption(op.req,88,policy,4)~=0,"No se pudo desactivar redirecciones")
    local context=ffi.new("uintptr_t[1]",ffi.cast("uintptr_t",op.state))
    assert(win.WinHttpSetOption(op.req,45,context,ffi.sizeof(context))~=0,"Fallo el contexto HTTP")
    local previous=win.WinHttpSetStatusCallback(op.req,runtime.callback,0x7a0800,0)
    assert(previous~=ffi.cast("void*",-1),"No se pudo activar WinHTTP asincrono")
    op.installed=true
    local headers="Authorization: "..authorization.."\r\n"
    if contentType then headers=headers.."Content-Type: "..contentType.."\r\n" end
    if depth then headers=headers.."Depth: "..depth.."\r\n" end
    op.headers=wide(headers)
    check(win.WinHttpSendRequest(op.req,op.headers,#headers,nil,0,#op.body,context[0]),"conexion")
  end)
  if not ok then op.finished=true;close();error(err) end
  later(poll)
  return op
end
CustomPanelKoofrHTTP=H
  http=H
end
-- OTC C++ bindings must always be called on its main Lua state.
-- Continuations are dispatched by the integrated HTTP transport through the OTC event loop.
local running
function D.run(task,done,progress)
  assert(not running,"Ya hay una operacion Koofr en curso")
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
  local job=assert(running,"Operacion Koofr fuera de una tarea")
  job.pending=http.start(method,url,body,contentType,authorization,depth,function(ok,data,status)
    job.pending=nil
    if running~=job then return end
    if not ok then job.finish(false,data) return end
    if not (accepted and accepted[status]) and not (status>=200 and status<300) then
      local message={
        [401]="Correo o contrasena de aplicacion de Koofr incorrectos.",
        [403]="Koofr no permite esta operacion.",
        [404]="No existe esa carpeta o archivo en Koofr.",
        [409]="Falta una carpeta intermedia en Koofr.",
        [429]="Koofr limita las solicitudes. Espera antes de volver a intentar.",
        [507]="No queda espacio suficiente en Koofr."
      }
      job.finish(false,message[status] or ("Koofr devolvio HTTP "..tostring(status)))
      return
    end
    job.call(callback,data,status)
  end,job.progress)
end
local credentials
local function account()
  if not credentials then
    assert(resources.fileExists(tokenFile),"Conecta tu cuenta de Koofr primero.")
    local ok,result=pcall(function()
      return json.decode(protect(resources.readFileContents(tokenFile),true))
    end)
    assert(ok and type(result)=="table","Vuelve a conectar Koofr en este Windows.")
    credentials=result
  end
  assert(type(credentials.user)=="string" and type(credentials.password)=="string","Vuelve a conectar Koofr.")
  return dav.basic(credentials.user,credentials.password)
end
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
  assert(user~="" and not user:find("[:%c]") and user:find("@",1,true),"Escribe tu correo de Koofr.")
  assert(type(password)=="string" and #password>0 and not password:find("[%c]"),"Escribe la contrasena de aplicacion WebDAV.")
  request("PROPFIND",dav.url("/"),propfind,"application/xml; charset=utf-8",dav.basic(user,password),"0",nil,function()
    local value={user=user,password=password}
    persist(value)
    credentials=value
    done("Cuenta de Koofr conectada.")
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
