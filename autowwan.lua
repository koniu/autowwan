#!/usr/bin/env lua
require("uci")
require("iwinfo")

--{{{ helper functions
---{{{ split
function split(str, pat)
   local t = {}  -- NOTE: use {n = 0} in Lua-5.0
   local fpat = "(.-)" .. pat
   local last_end = 1
   local s, e, cap = str:find(fpat, 1)
   while s do
      if s ~= 1 or cap ~= "" then
     table.insert(t,cap)
      end
      last_end = e+1
      s, e, cap = str:find(fpat, last_end)
   end
   if last_end <= #str then
      cap = str:sub(last_end)
      table.insert(t, cap)
   end
   return t
end
---}}}
---{{{ typify
function typify(t)
    for k, v in pairs(t) do
        vn = tonumber(v)
        if vn and k ~= "key" then t[k] = vn end
        if v == 'false' then v = false end
    end
    return t
end
---}}}
---{{{ pref_sort 
function pref_sort(a, b)
    local ascore = presets[a.ssid].score
    local bscore = presets[b.ssid].score
    if ascore or bscore then
        return (ascore or 0) > (bscore or 0)
    else
        return a.signal > b.signal
    end
end
---}}}
---{{{ sleep 
function sleep(t)
    os.execute("sleep "..t)
end
---}}}
---{{{ pread 
function pread(cmd)
    local f = io.popen(cmd)
    if not f then return end
    local output = f:read("*a")
    f:close()
    return output
end
---}}}
---{{{ fsize 
function fsize(file)
    local f = io.open(file)
    local size = f:seek("end")
    f:close()
    return size
end
---}}}
--}}}
--{{{ log functions
function log(msg, level, partial)
    local buf = logbuffer or {}
    local level = level or buf.level or 6
    local msg = (buf.msg or "") .. msg
    local time = buf.time or os.date("%Y-%m-%d %H:%M:%S")
    if level > ((cfg and cfg.log_level) or 5) then return end
    if partial then
        logbuffer = { msg = msg, time = time, level = level }
    else
        logbuffer = nil
        if cfg.syslog then
            os.execute(string.format("logger -t autowwan -p %d %s", level, msg))
        else
            local stamp = time .. " autowwan." .. log_levels[level] .. ": "
            io.stdout:write(stamp .. msg .. "\n")
        end
    end
end
--}}}
--{{{ uci functions
function get_uci_section()
    uwifi:load("wireless")
    uwifi:foreach("wireless", "wifi-iface", function(s)
        if s.autowwan and s.mode == "sta" then cfg.section=s[".name"] end end)

    ustate:load("wireless")
    cfg.iface = ustate:get("wireless", cfg.section, "ifname")
    cfg.device = ustate:get("wireless", cfg.section, "device")
    cfg.network = ustate:get("wireless", cfg.section, "network")
    iw = iwinfo[iwinfo.type(cfg.iface)]

    if not (cfg.section and cfg.iface and cfg.device) then
        log("no suitable device or interface found - exiting", 3)
        os.exit(1)
    end
end

function load_config()
    log("reading config")
    -- load config from uci
    ucfg:load("autowwan")
    cfg = ucfg:get_all("autowwan.config")
    cfg = typify(cfg)
    get_uci_section()
    -- get ignored ssids into a table
    ignored = {}
    for i, ssid in ipairs(split(cfg.ignore_ssids, ",")) do
        ignored[ssid] = true
    end
    -- fill missing options from defaults
    for k, v in pairs(defaults) do
        if not cfg[k] then cfg[k] = v end
    end
    -- get network presets from uci
    presets = {}
    ucfg:foreach("autowwan", "networks", function(net) presets[net.ssid] = typify(net) end)
    -- get test presets from uci
    local ts = {}
    ucfg:foreach("autowwan", "tests", function(test) table.insert(ts, typify(test)) end)
    if #ts > 0 then tests = ts else tests = default_tests end
end

--}}}
--{{{ net functions
---{{{ filter_results
function filter_results(results)
    local connectable = {}
    for i, ap in ipairs(results) do
        if not (ignored[ap.ssid] or (presets[ap.ssid] and presets[ap.ssid].ignore)) then
            if (not ap.encryption.enabled) and cfg.join_open then
                table.insert(connectable, ap)
                presets[ap.ssid] = { encryption = "none", key = "", score = 0 }
            elseif presets[ap.ssid] then
                table.insert(connectable, ap)
            end
        end
    end
    table.sort(connectable, pref_sort)
    log("found "..#connectable.." out of "..#results)
    return connectable
end
---}}}
---{{{ scan
function scan()
    log("scanning: ", 5, true)
    os.execute("ifconfig " .. cfg.iface .. " up")
    return iw.scanlist(cfg.iface)
end
---}}}
---{{{ ping
function ping(host, opts)
    local out = pread(string.format("ping %s %s 2>/dev/null", opts, host))
    return tonumber(out:match("/(%d+%.%d+)/"))
end
---}}}
---{{{ connect
function connect(ap)
    get_uci_section()
    os.execute("ifdown "..cfg.network)
    log(string.format("connecting to ap %s [%d%%, ch %d]", ap.ssid, math.floor((ap.quality*100)/ap.quality_max), ap.channel), 5)
    uwifi:set("wireless", cfg.section, "ssid", ap.ssid)
    uwifi:set("wireless", cfg.section, "encryption", presets[ap.ssid].encryption)
    uwifi:set("wireless", cfg.section, "key", presets[ap.ssid].key)
    uwifi:set("wireless", cfg.device, "channel", ap.channel)
    uwifi:save("wireless")
    uwifi:commit("wireless")
    os.execute("wifi reload "..cfg.device.." >& /dev/null")
    sleep(cfg.conn_timeout)
    stats = {}
    for i, test in ipairs(tests) do
        if test.conn then
            local result = testf[test.type](test)
            if not result then return end
        end
    end
    log("connected!", 5)
    return true
end
---}}}
---{{{ reconnect
function reconnect()
    log("reconnecting", 5)
    local connected
    while not connected do
        load_config()
        for i, ap in ipairs(filter_results(scan())) do
            connected = connect(ap)
            if connected then break end
        end
    end
end
---}}}
--}}}
--{{{ test functions
testf = {}
---{{{ ping
testf.ping = function(arg)
    log("ping test - ", nil, true)
    local p = ping(arg.host, arg.opts)
    update_stats(arg, p)
    if p then
        log(string.format("ok [%s, %.0fms, avg %.0fms, loss %.0f%%]", arg.host, p, stats[arg].avg, stats[arg].loss))
    else
        log("failed!")
    end
    return p
end
---}}}
---{{{ wifi
testf.wifi = function(arg)
    log("wifi test - ", nil, true)
    local q = iw.quality(cfg.iface)
    local qmax = iw.quality_max(cfg.iface)
    local p = math.floor((q*100)/qmax)
    update_stats(arg, p)
    if 
        iw.bssid(cfg.iface) and q > 0
    then
        local bitrate = iw.bitrate(cfg.iface) / 1000
        local ssid = iw.ssid(cfg.iface)
        log(string.format("ok [%s, %s%%, avg %.0f%%, %.1fMbps]", ssid, p, stats[arg].avg, bitrate))
        return p
    else
        log("failed!")
    end
end
---}}}
---{{{ ip
testf.ip = function()
    log("ip test   - ", nil, true)
    local wan = ustate:get_all("network", cfg.network)
    if not wan then
        log("failed [interface down]")
    elseif not wan.up then
        log("failed [not connected]")
    elseif not wan.ipaddr then
        log("failed [no IP address]")
    elseif not wan.gateway then
        log("failed [no gateway]")
    else
        log(string.format("ok [%s/%s gw %s]", wan.ipaddr, wan.netmask, wan.gateway))
        return wan
    end
end
---}}}
---{{{ dns
testf.dns = function(arg)
    log("dns test  - ", nil, true)
    local out = pread("nslookup "..arg.host)
    local name, addr = out:match("Name:.-([%w%p]+).*Address 1: (%d+%.%d+%.%d+%.%d+)")
    if name and addr then
        log(string.format("ok [%s -> %s]", name, addr))
        return true
    else
        log("failed")
    end
end
---}}}
---{{{ http
testf.http = function(arg)
    log("http test - ", nil, true)
    local start = os.time()
    local fn = arg.dest .. "/http_test"
    os.execute(string.format("wget -O%s %s >& /dev/null", fn, arg.url))
    local finish = os.time()
    local md5 = pread("md5sum "..fn):match("(%w+)")
    local bw = fsize(fn)/(finish-start)/1024
    update_stats(arg, bw)
    if arg.md5 == md5 then
        log(string.format("ok [md5sum good, %.0fKB/s, avg %0.fKB/s]", bw, stats[arg].avg))
        return true
    else
        log("failed [md5sum mismatch]")
    end
    os.execute("rm "..fn)
end
---}}}
--}}}
--{{{ stat functions
function update_stats(arg, res)
    local stat = stats[arg] or {}
    table.insert(stat, 1, res or "#fail#")
    if #stat > cfg.stat_buffer then
        table.remove(stat, cfg.stat_buffer)
    end
    local lost = 0
    local total = 0
    for i, res in ipairs(stat) do
        if res ~= "#fail#" then
            total = total + res
        else
            lost = lost + 1
        end
    end
    stat.loss = (lost*100)/#stat
    stat.avg = total/(#stat-lost)
    stats[arg] = stat
end
--}}}

--{{{ defaults
defaults = {
    join_open = true,
    ignore_ssids = "IgnoreMe,AndMe,MeToo",
    interval = 1,
    conn_timeout = 10,
    stat_buffer = 50,
    log_level = 5,
}

default_tests = {
    { type = "wifi", conn = true, interval = 1, retry_limit = 1 },
    { type = "ip", conn = true },
    { type = "ping", conn = true, interval = 1, retry_limit = 10,
        host = "8.8.8.8",
        opts = "-W 5 -c 1" },
    { type = "dns", conn = true, host = "google.com" },
    { type = "http", conn = true,
        url = "http://www.kernel.org/pub/linux/kernel/v2.6/ChangeLog-2.6.9",
        md5 = "b6594bd05e24b9ec400d742909360a2c",
        dest ="/tmp" },
}

log_levels = { "alert", "crit", "err", "warning", "notice", "info", "debug" }
--}}}
--{{{ init
uwifi = uci.cursor()
ucfg = uci.cursor()
ustate = uci.cursor(nil, "/var/state")

load_config()

stats = {}
iter = 0
--}}}
--{{{ main loop
while true do
    for i, test in ipairs(tests) do
        if test.interval and math.fmod(iter, test.interval) == 0 then
            local result = testf[test.type](test)
            if not result then
                test.failed = (test.failed or 0) + 1
                if test.failed >= test.retry_limit then
                    log(string.format("%s test - reached retry limit [%d]", test.type, test.retry_limit), 5)
                    iter = 0
                    reconnect()
                    break
                end
            else
                test.failed = 0
            end
        end
    end
    iter = iter + 1
    sleep(cfg.interval)
end
--}}}
-- vim: foldmethod=marker:filetype=lua:expandtab:shiftwidth=4:tabstop=4:softtabstop=4
