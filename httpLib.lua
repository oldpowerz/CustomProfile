-- WinHTTP asíncrono. Los hilos de Windows solo escriben seis DWORD.
-- Todo Lua, incluida la UI, se ejecuta desde el event loop de OTC.
local ffi=modules.corelib.require("ffi")
local kernel=ffi.load("kernel32")
local win=ffi.load("winhttp")
local owner=modules.game_bot
if not owner.customBotAsyncHTTPDefs then
  ffi.cdef[[
typedef void *CB_HANDLE;
int __stdcall MultiByteToWideChar(unsigned int,unsigned long,const char*,int,uint16_t*,int);
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
  local hex=assert(machine[ffi.arch],"Arquitectura no compatible con el transporte HTTP")
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
  local roots={
    ["app.koofr.net"]="/dav/Koofr/",
    ["webdav.pcloud.com"]="/",
    ["ewebdav.pcloud.com"]="/"
  }
  local root=roots[host]
  assert(root and path and path:sub(1,#root)==root,"Destino HTTPS invalido")
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
CustomPanelHTTP=H
