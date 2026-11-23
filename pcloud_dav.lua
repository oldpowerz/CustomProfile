-- Utilidades WebDAV para pcloud.
CustomPanelPCloudDAV = {}
function CustomPanelPCloudDAV.create(provider)
  assert(type(provider) == "table" and provider.host and provider.root, "Proveedor WebDAV invalido")
  local M = {}
  function M.path(path)
    assert(type(path)=="string" and #path<=1500,"Ruta de nube invalida")
    path="/"..path:gsub("^/+",""):gsub("/+$","")
    assert(not path:find("[%c\\?#]") and not path:find("//",1,true),"Ruta de nube invalida")
    for part in path:gmatch("[^/]+") do assert(part~="." and part~="..","Ruta de nube invalida") end
    return path
  end
  function M.escape(s)
    return (s:gsub("([^%w%-_%.~])",function(c)return string.format("%%%02X",c:byte())end))
  end
  function M.url(path)
    path=M.path(path)
    local parts={}
    for p in path:gmatch("[^/]+")do parts[#parts+1]=M.escape(p) end
    return "https://"..provider.host..provider.root.."/"..table.concat(parts,"/")
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
    assert(document:find("<[%w_%-]*:?multistatus[%s>]"),"La nube no devolvio una lista WebDAV")
    folder=M.path(folder)
    local prefix=provider.root..(folder=="/" and "" or folder)
    local entries,seen={},{}
    -- WebDAV puede usar cualquier prefijo XML (d:, D:, ns0:) o ninguno.
    for block in document:gmatch("<[%w_%-]*:?response[%s>].-</[%w_%-]*:?response%s*>") do
      local raw=block:match("<[%w_%-]*:?href[^>]*>(.-)</[%w_%-]*:?href%s*>")
      local success=block:match("<[%w_%-]*:?status[^>]*>HTTP/[%d%.]+%s+200%s")
      if raw and success then
        local href=xml(raw)
        if href:match("^https://") then
          local host,rest=href:match("^https://([^/]+)(/.*)$")
          assert(host==provider.host,"Servidor WebDAV inesperado")
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
  return M
end
