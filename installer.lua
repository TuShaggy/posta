-- /installer.lua
-- One-step installer from your GitHub. Descarga shaggy.lua, lib/f.lua y startup.lua (más la ui/theme.lua si la mantienes).

-- >>> EDITA AQUÍ SI CAMBIAS DE REPO <<<
local GITHUB_USER   = "TuShaggy"
local GITHUB_REPO   = "posta"
local GITHUB_BRANCH = "main"
-- >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>

local FILES = {
  ["installer.lua"]  = "installer.lua",
  ["lib/f.lua"]   = "lib/f.lua",
  ["startup.lua"] = "startup.lua",     -- script que se ejecutará al arrancar
}

local function raw_url(path)
  return ("https://raw.githubusercontent.com/%s/%s/%s/%s")
         :format(GITHUB_USER, GITHUB_REPO, GITHUB_BRANCH, path)
end

local function ensure_dir(path)
  local dir = path:match("^(.*)/[^/]+$")
  if dir and dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
end

local function download(url)
  local h = http.get(url)
  if not h then return nil, "HTTP GET failed" end
  local data = h.readAll()
  h.close()
  if not data or #data == 0 then return nil, "Empty response" end
  return data
end

local function write_file(path, data)
  ensure_dir(path)
  local f = fs.open(path, "w")
  f.write(data)
  f.close()
end

local function main()
  if not http then error("HTTP API disabled. Enable it in CC:Tweaked config.") end
  print(("== Installer: %s/%s (%s) =="):format(GITHUB_USER, GITHUB_REPO, GITHUB_BRANCH))
  for remote, localPath in pairs(FILES) do
    print("Downloading "..remote.." ...")
    local data, err = download(raw_url(remote))
    if not data then
      printError("Failed: "..remote.." ("..tostring(err)..")")
    else
      write_file(localPath, data)
      print("Saved -> "..localPath)
      -- también se guarda lib/f sin extensión para os.loadAPI("lib/f")
      if remote == "lib/f.lua" then
        write_file("lib/f", data)
        print("Saved -> lib/f")
      end
    end
  end
  print("Install complete. Reboot now? (y/n)")
  local a = read()
  if a and a:lower():sub(1,1) == "y" then os.reboot() end
end

local ok, err = pcall(main)
if not ok then printError("installer error: "..tostring(err)) end
