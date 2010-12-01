#!/usr/bin/env lua
require("uci")
require("iwinfo")

--{{{ defaults
defaults = {
    iface = wlan0,
    conn_timeout = 10,
    check_interval = 1,
    ping_failed_limit = 10,
    ping_stat_count = 10,
    ping_test_host = "8.8.8.8",
    ping_opts = "-W 5 -c 1",
    join_open = true,
    ignore_ssids = "IgnoreMe,AndMe,MeToo",
    http_test_url = "http://www.kernel.org/pub/linux/kernel/v2.6/ChangeLog-2.6.9",
    http_test_md5 = "b6594bd05e24b9ec400d742909360a2c",
    http_test_dest = "/tmp",
    dns_test_host = "google.com",
}

logs = {     
    err     = { header = "error",     level = 0 },
    warn    = { header = "warning", level = 1 },
    info    = { header = "info",     level = 2 },
    dbg     = { header = "debug",   level = 3 },
}

log_level = 2

--}}}

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
        if vn then t[k] = vn end
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
function log(msg, l, nonl)
    local l = l or logs.info
    if l.level > log_level then return end
    local nl = (nonl and "") or "\n"
    local time = os.date("%Y-%m-%d %H:%M:%S")
    local stamp = time .. " autowwan." .. l.header .. ": "
    io.stdout:write(stamp .. msg .. nl)
end
function log_result(msg, l)
    local l = l or logs.info
    if l.level > log_level then return end
    io.stdout:write(msg.."\n")
end
--}}}
--{{{ uci functions
function get_uci_section()
    uwifi:load("wireless")
    uwifi:foreach("wireless", "wifi-iface", function(s)
        if s.autowwan and s.mode == "sta" then cfg.section=s[".name"] end end)

    if not cfg.section then
        log("no suitable interfaces found", logs.err)
        os.exit(1)
    end
end

function update_config()
    ucfg:load("autowwan")
    log("reading config", logs.info)
    cfg = ucfg:get_all("autowwan.config")
    ignored = {}
    for i, ssid in ipairs(split(cfg.ignore_ssids, ",")) do
        ignored[ssid] = true
    end
    cfg = typify(cfg)
    for k, v in pairs(defaults) do
        if not cfg[k] then cfg[k] = v end
    end
    get_uci_section()
end

function update_presets()
    ucfg:load("autowwan")
    log("reading presets", logs.info)
    presets = {}
    ucfg:foreach("autowwan", "networks", function(net) presets[net.ssid] = typify(net) end)
end
--}}}
--{{{ net functions
---{{{ update_connectable
function update_connectable()
    connectable = {}
    for i, ap in ipairs(range) do
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
    log_result("found "..#connectable.." out of "..#range, logs.info)
end
---}}}
---{{{ update_range
function update_range()
    log("scanning: ", logs.info, 1)
    os.execute("ifconfig " .. cfg.iface .. " up")
    range = iwinfo.nl80211.scanlist(cfg.iface)
end
---}}}
---{{{ ping
function ping(host)
    local out = pread(string.format("ping %s %s 2>/dev/null", cfg.ping_opts, host))
    return tonumber(out:match("/(%d+%.%d+)/"))
end
---}}}
---{{{ connect
function connect(ap)
    get_uci_section()
    failed = cfg.ping_failed_limit
    os.execute("ifdown wan")
    log("connecting to ap: "..ap.ssid, logs.info)
    uwifi:set("wireless", cfg.section, "ssid", ap.ssid)
    uwifi:set("wireless", cfg.section, "encryption", presets[ap.ssid].encryption)
    uwifi:set("wireless", cfg.section, "key", presets[ap.ssid].key)
    uwifi:save("wireless")
    uwifi:commit("wireless")
    os.execute("wifi >& /dev/null")
    sleep(cfg.conn_timeout)
    if wifi_test() and ip_test() and ping_test() and dns_test() and http_test() then
        log("connected!")
        failed = 0
        return true
    end
end
---}}}
---{{{ reconnect
function reconnect()
    log("reconnecting")
    local connected
    while not connected do
        update_config()
        update_presets()
        update_range()
        update_connectable()
        for i, ap in ipairs(connectable) do
            connected = connect(ap)
            if connected then break end
        end
    end
end
---}}}
--}}}
--{{{ test functions
---{{{ ping_test
function ping_test()
    log("ping test - ", logs.info, 1)
    local p = ping(cfg.ping_test_host)
    update_stats(p)
    if p then
        log_result(string.format("ok [%s, %.0fms, avg %.0fms, loss %.0f%%]", cfg.ping_test_host, p, stats.avg, stats.loss))
    else
        log_result("failed!")
    end
    return p
end
---}}}
---{{{ wifi_test
function wifi_test()
    log("wifi test - ", logs.info, 1)
    local q = iwinfo.nl80211.quality(cfg.iface)
    local qmax = iwinfo.nl80211.quality_max(cfg.iface)
    local p = math.floor((q*100)/qmax)
    if 
        iwinfo.nl80211.bssid(cfg.iface) and q > 0
    then 
        log_result(string.format("ok [%s, %s%%]", iwinfo.nl80211.ssid(cfg.iface), p))
        return p
    else
        log_result("failed!")
    end
end
---}}}
---{{{ ip_test
function ip_test()
    log("ip test   - ", logs.info, 1)
    wan = ustate:get_all("network", "wan")
    if not wan then
        log_result("failed [interface down]")
    elseif not wan.up then
        log_result("failed [not connected]")
    elseif not wan.ipaddr then
        log_result("failed [no IP address]")
    elseif not wan.gateway then
        log_result("failed [no gateway]")
    else
        log_result(string.format("ok [%s/%s gw %s]", wan.ipaddr, wan.netmask, wan.gateway))
        return wan
    end
end
---}}}
---{{{ dns_test
function dns_test()
    log("dns test  - ", logs.info, 1)
    local out = pread("nslookup "..cfg.dns_test_host)
    local name, addr = out:match("Name:.-([%w%p]+).*Address 1: (%d+%.%d+%.%d+%.%d+)")
    if name and addr then
        log_result(string.format("ok [%s -> %s]", name, addr))
        return true
    else
        log_result("failed")
    end
end
---}}}
---{{{ http_test
function http_test()
    log("http test - ", logs.info, 1)
    local start = os.time()
    local fn = cfg.http_test_dest .. "/http_test"
    os.execute(string.format("wget -O%s %s >& /dev/null", fn, cfg.http_test_url))
    local finish = os.time()
    local md5 = pread("md5sum "..fn):match("(%w+)")
    local bw = fsize(fn)/(finish-start)/1024
    if cfg.http_test_md5 == md5 then
        log_result(string.format("ok [md5sum good, %.0fKB/s]", bw))
        return true
    else
        log_result("failed [md5sum mismatch]")
    end
    os.execute("rm "..fn)
end
---}}}
--}}}
--{{{ stat functions
function update_stats(p)
    table.insert(pings, 1, p)
    if table.maxn(pings) > cfg.ping_stat_count then
        table.remove(pings,table.maxn(pings))
    end
    local count = table.maxn(pings)
    local lost = 0
    local total = 0
    table.foreachi(pings, function(i,p) 
        if p then 
            total = total + p  
        else
            lost = lost + 1
        end
    end)
    stats.loss = (lost*100)/count
    stats.avg = total/(count-lost)
end
--}}}

--{{{ init
pings = {}
stats = {}

uwifi = uci.cursor()
ucfg = uci.cursor()
ustate = uci.cursor(ni, "/var/state")

update_config()

failed = cfg.ping_failed_limit
--}}}
--{{{ main loop
while true do
    if not wifi_test() then
        reconnect()
    else 
        local p = ping_test()
        if p then
            failed = 0
        else
            if failed == cfg.ping_failed_limit then
                log("missed "..cfg.ping_failed_limit.." pings")
                reconnect()
            else
                failed = failed + 1
            end
        end
    end
    sleep(cfg.check_interval)
end
--}}}
-- vim: foldmethod=marker:filetype=lua:expandtab:shiftwidth=4:tabstop=4:softtabstop=4
