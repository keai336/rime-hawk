--[[
    aux_refactored_v2_debug.lua
    版本: v2_debug (修复修音崩溃 + 保留调试日志)

    基于 aux_refactored_v1 (核心重构: Memory API 替代音码列)
    修复: 修音分支中 inputspls 被就地修改，污染 split_pinyin 缓存导致崩溃

    修复说明:
    - 问题: 修音分支直接修改 inputspls[S.ficompensate + 1] = ybmodif，
            但 inputspls 是 split_pinyin() 返回的（可能被缓存），
            下一轮再次调用 split_pinyin 时会命中被修改过的缓存数组，
            导致 inputspls 内容不一致，引发越界访问崩溃。
    - 修复: 修音分支中不直接修改 inputspls，
            而是从原始 preedit 重新创建新数组，
            避免污染缓存。
    - 修复: 增加越界安全检查，防止崩溃。

    调试日志输出到: 用户数据目录/debug_breakpoint.log
    格式: JSON Lines (每行一个 JSON 对象)

    使用方法:
    1. 复制到 Rime 部署目录
    2. 在方案 YAML 中引用此文件
    3. 触发问题操作
    4. 查看 debug_breakpoint.log 或使用 docs/log_parser.html 解析
]]

local http = {}
local ok, mod = pcall(require, "simplehttp")
if ok then
    http = mod
else
    http.request = function(url)
        return ""
    end
end
http.TIMEOUT = 0.1
local AuxFilter = {}

-- ============================================
-- 调试日志开关 (设为 false 关闭日志输出)
-- ============================================
local DEBUG_MODE = true

-- ============================================
-- 调试日志系统
-- ============================================
local debugLogPath = DEBUG_MODE and rime_api.get_user_data_dir() .. "/debug_breakpoint.log" or nil
local debugfile = debugLogPath and io.open(debugLogPath, "a") or nil

local session_id = DEBUG_MODE and os.date("%Y%m%d_%H%M%S_") .. tostring(math.random(1000, 9999)) or nil

local function json_escape(str)
    if type(str) ~= "string" then return tostring(str) end
    str = str:gsub('\\', '\\\\')
    str = str:gsub('"', '\\"')
    str = str:gsub('\n', '\\n')
    str = str:gsub('\r', '\\r')
    str = str:gsub('\t', '\\t')
    return str
end

local function table_to_json(t)
    if type(t) ~= "table" then return "null" end
    local parts = {}
    local is_array = (t[1] ~= nil)
    for k, v in pairs(t) do
        local val
        if type(v) == "table" then
            val = table_to_json(v)
        elseif type(v) == "string" then
            val = '"' .. json_escape(v) .. '"'
        elseif type(v) == "boolean" then
            val = v and "true" or "false"
        elseif v == nil then
            val = "null"
        else
            val = tostring(v)
        end
        if is_array then
            table.insert(parts, val)
        else
            table.insert(parts, '"' .. json_escape(tostring(k)) .. '":' .. val)
        end
    end
    if is_array then
        return "[" .. table.concat(parts, ",") .. "]"
    else
        return "{" .. table.concat(parts, ",") .. "}"
    end
end

local function debug_log(data)
    if not DEBUG_MODE or not debugfile then return end
    data.session = session_id
    data.timestamp = os.date("%Y-%m-%d %H:%M:%S")
    local json_str = table_to_json(data)
    debugfile:write(json_str .. "\n")
    debugfile:flush()
end

local function start_debug_session()
    if not DEBUG_MODE then return end
    if DEBUG_MODE then
    debug_log({
        event = "session_start",
        version = "v2_debug",
        fix_description = "修复修音分支 inputspls 缓存污染崩溃"
    })
    end
end

start_debug_session()
-- ============================================

local logFilePath = rime_api.get_user_data_dir() .. "/dic.log"
local dicfile = io.open(logFilePath, "a")
local function logdic(message)
    if dicfile then
        local time = os.date("%Y-%m-%d %H:%M:%S")
        local logMessage = string.format("[%s] %s\n", time, message)
        dicfile:write(logMessage)
        dicfile:flush()
    else
        log.info("无法打开日志文件")
    end
end

local baseurl = "http://127.0.0.1:8080"
local function fetch_api_config()
    local config_url = baseurl .. "/config"
    local res = http.request(config_url)
    if res == "" then
        return nil
    end
    local config_table = {}
    for line in res:gmatch("[^\r\n]+") do
        local key, value = line:match("^(%S+)%s+(.*)$")
        if key and value then
            config_table[key] = value
        end
    end
    return config_table
end

local luyz = fetch_api_config()
local function onereq(key,inp)
    local lu = (luyz and luyz[key]) or ""
    local url = baseurl..lu..inp
    local res = http.request(url)
    return res
end

local function str_table(tbl)
    local lines = {}
    for k, v in pairs(tbl) do
        table.insert(lines, tostring(k) .. "=" .. tostring(v))
    end
    return table.concat(lines, "\n")
end

local function table_empty(t)
    return next(t) == nil
end

-- 清空表内容但保留底层哈希桶的物理内存，减少 GC 分配
local function clear_table(t)
    if not t then return {} end
    for k in pairs(t) do t[k] = nil end
    return t
end

local function countSubstringOccurrences(str, substr)
    if not str or substr == "" then return 0 end
    local _, count = string.gsub(str, substr, "")
    return count
end

local function utf8len(str)
    return utf8.len(str) or 0
end

local function utf8sub(str, i, j)
    local len = utf8len(str)
    if i < 0 then i = len + i + 1 end
    if j == nil then j = len elseif j < 0 then j = len + j + 1 end
    if i > j or i < 1 then return "" end
    local start_byte = utf8.offset(str, i)
    if not start_byte then return "" end
    local end_byte = utf8.offset(str, j + 1)
    return end_byte and str:sub(start_byte, end_byte - 1) or str:sub(start_byte)
end

function AuxFilter.init(env)
    local engine = env.engine

    -- ========================================
    -- 1. 解析 name_space 配置（格式: path@showor@trigger@switch@ph@matchmode）
    -- ========================================
    local defaults = {
        path      = "ZRM_Aux-code",
        showor    = "on",
        trigger   = ";",
        switch    = "`",
        ph        = ",",
        matchmode = "s",
    }
    local param_order = {"path", "showor", "trigger", "switch", "ph", "matchmode"}
    local params = {}
    for seg in env.name_space:gmatch("([^@]+)") do
        params[#params + 1] = seg
    end
    local cfg = {}
    for i, key in ipairs(param_order) do
        cfg[key] = params[i] or defaults[key]
    end

    -- ========================================
    -- 2. 从配置派生运行时变量
    -- ========================================
    local function escape_pattern(s) return s:gsub("(%W)", "%%%1") end

    AuxFilter.trigger_key         = cfg.trigger
    AuxFilter.trigger_key_pattern = escape_pattern(cfg.trigger)
    AuxFilter.ph                  = cfg.ph
    AuxFilter.ph_pattern          = escape_pattern(cfg.ph)
    AuxFilter.switch_key          = escape_pattern(cfg.switch)
    AuxFilter.matchmode           = (cfg.matchmode == "s") and 1 or 0
    AuxFilter.show_aux_notice     = (cfg.showor ~= "off")
    logdic("基礎配置加載成功")

    -- ========================================
    -- 3. 加载资源（辅码表、OpenCC、Memory、Preedit Projection）
    -- ========================================
    local preedit_config = engine.schema.config:get_list("translator/preedit_format1")
    if preedit_config then
        AuxFilter.preedit_trans = Projection()
        AuxFilter.preedit_trans:load(preedit_config)
        logdic("preedit_trans 加載成功")
    else
        AuxFilter.preedit_trans = nil
    end

    if not AuxFilter.aux_code then
        AuxFilter.readAuxTxt(cfg.path)
        logdic("readAuxTxt 成功")
    end

    if not AuxFilter.opencc then
        AuxFilter.opencc = Opencc("s2t.json")
    end

    if not AuxFilter.mem then
        local ok, mem = pcall(Memory, engine, engine.schema, "translator")
        if ok and mem then
            AuxFilter.mem = mem
            AuxFilter.longcandimodify_flag = true
            logdic("Memory 初始化成功")
            if DEBUG_MODE then
                debug_log({event = "memory_init", status = "success"})
            end
        else
            AuxFilter.mem = nil
            AuxFilter.longcandimodify_flag = false
            logdic("Memory 初始化失败，断句功能不可用")
            if DEBUG_MODE then
                debug_log({event = "memory_init", status = "failed"})
            end
        end
    end

    -- ========================================
    -- 4. 预编译输入匹配模式
    -- ========================================
    local tkp = AuxFilter.trigger_key_pattern
    local php = AuxFilter.ph_pattern
    local skp = AuxFilter.switch_key

    AuxFilter.pattern_main1            = "^[^" .. tkp .. "]+" .. tkp .. "[%a" .. AuxFilter.ph .. "]*$"
    AuxFilter.pattern_singlechar_switch = "^[^" .. tkp .. "]+" .. tkp .. "%a*" .. skp .. "$"
    AuxFilter.pattern_long             = "^[^" .. tkp .. "]+" .. tkp .. "%a*" .. tkp .. "+%a*$"
    AuxFilter.pattern_removeAux        = "^([^" .. tkp .. "]*)" .. tkp .. "-"
    AuxFilter.pattern_removetransd     = "^[^a-z;]*([%a;]*)"
    -- transform_input_code 用到的正则
    AuxFilter.pattern_transform = "^([^" .. php .. tkp .. "]+)"
                                  .. tkp .. "*" .. php
                                  .. "([^" .. php .. tkp .. "]*)$"
    AuxFilter.repl_transform    = "%1" .. AuxFilter.trigger_key .. AuxFilter.ph .. AuxFilter.ph .. "%2"

    -- ========================================
    -- 5. 连接事件通知
    -- ========================================
    env.update_notifier = engine.context.update_notifier:connect(function(ctx)
        if not ctx:is_composing() and AuxFilter.state then
            AuxFilter.state.single_flag = false
            AuxFilter.state.one_aux_firstcode = nil
            AuxFilter.state.aux_left = nil
            AuxFilter.state.transedtext = nil
        end
    end)
    env.notifier = engine.context.select_notifier:connect(function(ctx)
        local S = AuxFilter.state
        if S and S.notifiermark == 1 then
            AuxFilter.main1_notifier(ctx)
        elseif S and S.notifiermark == 2 then
            AuxFilter.longcandimodify_notifier(ctx)
        elseif S and S.notifiermark == 3 then
            AuxFilter.longcandimodify_ybnotifier(ctx)
        end
    end)
end

function AuxFilter.main1_notifier(ctx)
    local S = AuxFilter.state
    if S.transedtext ~= nil then
        AuxFilter.env.engine:commit_text(S.transedtext)
        S.transedtext = nil
        ctx:clear()
        return
    end
    AuxFilter.Update_codes(ctx)
    if S.removetransdInput ~= "" then
        S.last_fist_commit = nil  -- 隐式输入轮，不继承去重状态
        S.aux_left = S.aux_left or ""
        ctx.input = S.removeAuxInput .. AuxFilter.trigger_key .. S.aux_left
    else
        ctx.input = S.removeAuxInput
        S.single_flag = false
        ctx:commit()
    end
end

function AuxFilter.longcandimodify_notifier(ctx)
    local S = AuxFilter.state
    AuxFilter.Update_codes(ctx)
    S.single_flag = false
    local auxcode = S.inputCode:match(AuxFilter.trigger_key_pattern.. "(%a*)".. AuxFilter.trigger_key_pattern)
    if S.removetransdInput ~= "" then
        S.last_fist_commit = nil  -- 隐式输入轮，不继承去重状态
        ctx.input = S.removeAuxInput .. AuxFilter.trigger_key .. auxcode
    else
        ctx.input = S.removeAuxInput
        ctx:commit()
    end
end

function AuxFilter.longcandimodify_ybnotifier(ctx)
    local S = AuxFilter.state
    S.single_flag = false
    ctx.input = S.ybmodifiedcode
end

local function split(str, sep)
    local result = {}
    if str == "" then
        return result
    end
    for part in string.gmatch(str, "([^" .. sep .. "]+)") do
        table.insert(result, part)
    end
    return result
end

function AuxFilter.readAuxTxt(txtpath)
    local defaultFile = 'ZRM_Aux-code_4.3.txt'
    local userPath = rime_api.get_user_data_dir() .. "/lua/"
    local fileAbsolutePath = userPath .. txtpath .. ".txt"
    local file = io.open(fileAbsolutePath, "r") or io.open(userPath .. defaultFile, "r")
    if not file then
        logdic("ERROR: Unable to open auxiliary code file: " .. fileAbsolutePath)
        return {}
    end
    local auxCodesSet = {}
    for line in file:lines() do
        line = line:match("[^\r\n]+")
        if line and line ~= "" then
            local zi, fu = string.match(line, "^([^\t]+)\t([^\t]+)")
            if zi and fu then
                local fuls = split(fu, ",")
                for _, fuone in ipairs(fuls) do
                    auxCodesSet[zi] = auxCodesSet[zi] or {}
                    auxCodesSet[zi][fuone] = true
                end
            end
        end
    end
    local auxCodes = {}
    for zi, fu_set in pairs(auxCodesSet) do
        local result = nil
        for fu in pairs(fu_set) do
            result = result and (result .. "," .. fu) or fu
        end
        auxCodes[zi] = result
    end
    AuxFilter.aux_code = auxCodes
    file:close()

    -- 预计算所有单字的 fullAux（一次性，避免热路径运行时计算）
    local precomputed = {}
    local precomputed_count = 0
    for zi, codes in pairs(auxCodes) do
        if utf8len(zi) == 1 then
            local s1, s2 = {}, {}
            for code in codes:gmatch("[^,]+") do
                s1[#s1 + 1] = code:sub(1, 1)
                if #code > 1 then
                    s2[#s2 + 1] = code:sub(2, 2)
                end
            end
            precomputed[zi] = {table.concat(s1), table.concat(s2)}
            precomputed_count = precomputed_count + 1
        end
    end
    AuxFilter.fullAux_precomputed = precomputed
    logdic("fullAux 预计算完成，单字数: " .. precomputed_count)

    return auxCodes
end

function AuxFilter.fullAux(env, word)
    local s1, s2 = "", ""
    for _, codePoint in utf8.codes(word) do
        local char = utf8.char(codePoint)
        local charAuxCodes = AuxFilter.aux_code[char]
        if charAuxCodes then
            for code in charAuxCodes:gmatch("[^,]+") do
                s1 = s1 .. code:sub(1, 1)
                if #code > 1 then
                    s2 = s2 .. code:sub(2, 2)
                end
            end
        end
    end
    return {s1, s2}
end

function AuxFilter.match(fullAux, auxStr)
    if #fullAux == 0 then
        return false
    end
    local a1 = string.byte(auxStr, 1)
    if #auxStr == 1 then
        for i = 1, #fullAux[1] do
            if string.byte(fullAux[1], i) == a1 then return true end
        end
        if AuxFilter.matchmode == 0 then
            for i = 1, #fullAux[2] do
                if string.byte(fullAux[2], i) == a1 then return true end
            end
        end
        return false
    end
    local a2 = string.byte(auxStr, 2)
    for i = 1, #fullAux[1] do
        local f1 = string.byte(fullAux[1], i)
        local f2 = string.byte(fullAux[2], i)
        if f1 == a1 and f2 == a2 then return true end
        if AuxFilter.matchmode == 0 and f2 == a1 and f1 == a2 then return true end
    end
    return false
end

local function isCharInFirstPosition(char, codes)
    if not char or not codes then return false end
    for code in codes:gmatch("[^,]+") do
        if code:sub(1, 1) == char then return true end
    end
    return false
end

local pinyin_cache = {}
local function split_pinyin(pinyin_str)
    if not pinyin_str or pinyin_str == "" then return {} end
    local cached = pinyin_cache[pinyin_str]
    if cached then return cached end
    local syllables = {}
    for syllable in pinyin_str:gmatch("[^ ]+") do
        syllables[#syllables + 1] = syllable
    end
    pinyin_cache[pinyin_str] = syllables
    return syllables
end

local function slice(tbl, start_idx, end_idx)
    local sliced = {}
    for i = start_idx, end_idx do
        table.insert(sliced, tbl[i])
    end
    return sliced
end

local function sum_lengths(slice, n)
    if not slice or n <= 0 then return 0 end
    local total = 0
    for i, str in ipairs(slice) do
        if i > n then break end
        total = total + (str and #str or 0)
    end
    return total
end

local function transform_preedit(tbl, n)
    if not tbl or n <= 0 or not AuxFilter.preedit_trans then return tbl or {} end
    local result = {}
    local apply = AuxFilter.preedit_trans.apply
    for i = 1, n do
        result[i] = tbl[i] and apply(AuxFilter.preedit_trans, tbl[i], true) or tbl[i]
    end
    return result
end

local candisub= {}
candisub.__index = candisub

function candisub:new(cand, s_len)
    local S = AuxFilter.state
    local self = setmetatable({}, candisub)
    self.rawcand = cand
    self.cand = cand
    self.type = cand.type
    self.ftext = cand.text
    self.line = false
    local rawflag = true
    local preedit_flag = true
    if cand:get_dynamic_type() == "Shadow" then
        self.ftext = cand:get_genuine().text
        rawflag = false
    end
    if cand.type == "completion" or cand.type:find("table") then
        preedit_flag = false
    end
    local preeditls = split_pinyin(cand.preedit)
    local rlen = #preeditls
    local zlen = utf8len(cand.text)
    local len = rlen
    if rlen == zlen then
        self.line = true
        local ficompensate = math.min(0, S.rightcompen - S.leftcompen)
        if ficompensate ~= 0 or s_len ~= nil then
            if s_len then
               S.last_fist_commit = {}
            end
            S.prelen = s_len or S.firstcand_len or zlen
            local target_prelen = S.prelen + ficompensate
            if target_prelen <= rlen then
                len = math.max(1, target_prelen)
                local textsub = utf8sub(cand.text, 1, len)
                local fend = cand._start + sum_lengths(preeditls, len)
                self.cand = Candidate(cand.type, cand._start, fend, textsub, cand.comment)
            end
        end
    end
    local final_preedit_parts = (len == rlen) and preeditls or slice(preeditls, 1, len)
    if preedit_flag then
        final_preedit_parts = transform_preedit(final_preedit_parts, len)
    end
    local final_preedit = table.concat(final_preedit_parts, " ")
    if rawflag or S.yieldset[self.ftext] then
        self.cand.preedit = final_preedit
    end
    return self
end

function AuxFilter.yield_candisub(cand)
    local S = AuxFilter.state
    local finalcandi = cand
    if S.yieldrawset[finalcandi.rawcand.text] then
        return
    end
    local last_commit = S.last_fist_commit or {}
    local counter = S.counter or 0
    local aux_str = S.auxStr or ""
    local aux_len = #aux_str
    if counter == 0 and aux_len > 0 and aux_len <= 2 then
        if last_commit[1] == finalcandi.rawcand.text or
           (aux_len == 2 and last_commit[2] == finalcandi.rawcand.text) then
            return
        end
    end
    if not S.turned then
        S.yieldrawset[finalcandi.rawcand.text] = true
    end
    if S.skipc > 0 then
        S.skipc = S.skipc - 1
        return
    end
    local cand_text = finalcandi.cand.text
    if S.yieldset[cand_text] then
        return
    end
    if not S.turned then
        S.yieldset[cand_text] = true
    end
    S.counter = counter + 1
    if counter == 0 then
        S.firstcand_len = utf8len(finalcandi.rawcand.text)
        if aux_len < 2 then
            last_commit[aux_len + 1] = finalcandi.rawcand.text
        end
        S.last_fist_commit = last_commit
        if aux_len == 1 then
            S.one_aux_firstcode = utf8sub(cand_text,1,1)
        end
    end
    local cand = finalcandi.cand
    local candtext = cand.text
    if S.counter == 1 and (S.dupc ~= 1 or S.transor or S.rawor) then
        candtext = S.transdcode:gsub("‸","") .. cand.text
        if S.dupc ~= 1 then
            candtext = string.rep(candtext, S.dupc)
            cand.comment = "复制" .. tostring(S.dupc) .. "次"
        end
        if S.transor == true then
            if S.trans_target == nil then
                candtext = AuxFilter.opencc:convert(candtext)
            else
                local res = onereq(S.trans_target, candtext)
                if res == "" then
                    cand.comment = S.trans_target .. "空引导"
                else
                    candtext = res
                end
            end
        end
        if S.rawor == true and S.raw_target then
            local rawInput = S.removeAuxInput or ""
            local res = onereq(S.raw_target, rawInput)
            if res == "" then
                cand.comment = S.raw_target .. "空引导"
            else
                candtext = res
            end
        end
        cand = Candidate(cand.type, 0, cand._end, candtext, cand.comment)
        S.transedtext = candtext
    end
    yield(cand)
end

-- 进程级缓存
local syllable_aux_cache = {}

-- 带调试日志的 get_syllable_aux_set
local function get_syllable_aux_set(syllable)
    local cached = syllable_aux_cache[syllable]
    if cached ~= nil then
        if DEBUG_MODE then
        debug_log({
            event = "get_syllable_aux_set",
            step = "cache_hit",
            syllable = syllable,
            status = cached ~= false and "found" or "empty_cached"
        })
        end
        -- false 表示已知无辅码音节，直接拦截，避免重复 iter_dict 全表扫描
        return cached ~= false and cached or nil
    end

    if not AuxFilter.mem then
        if DEBUG_MODE then
        debug_log({
            event = "get_syllable_aux_set",
            step = "no_memory",
            syllable = syllable,
            status = "failed",
            reason = "Memory not initialized"
        })
        end
        return nil
    end

    -- 辅助函数：遍历 iter_dict 收集辅码集合
    local function collect_aux_from_iter(mode)
        local raw_aux_set = {}
        -- 仅 Debug 模式才分配 char_list，生产模式零 GC 压力
        local char_list = DEBUG_MODE and {} or nil
        local entry_count = 0
        local single_char_count = 0
        local has_aux_count = 0
        local has_any = false

        for entry in AuxFilter.mem:iter_dict() do
            entry_count = entry_count + 1
            -- aux_code 只存单字 key，多字词查表必返回 nil，天然跳过 utf8len
            local codes = AuxFilter.aux_code[entry.text]
            if codes then
                single_char_count = single_char_count + 1
                has_aux_count = has_aux_count + 1
                has_any = true
                if char_list then table.insert(char_list, entry.text) end
                for code in codes:gmatch("[^,]+") do
                    raw_aux_set[code] = true
                end
            end
        end

        if DEBUG_MODE then
        debug_log({
            event = "get_syllable_aux_set",
            step = "iter_dict_result",
            syllable = syllable,
            total_entries = entry_count,
            single_char_entries = single_char_count,
            entries_with_aux = has_aux_count,
            char_list = table.concat(char_list, ","),
            mode = mode
        })
        end

        return raw_aux_set, char_list, has_any, single_char_count
    end

    -- 第一步：精确匹配
    if DEBUG_MODE then
    debug_log({
        event = "get_syllable_aux_set",
        step = "before_dict_lookup",
        syllable = syllable,
        syllable_len = #syllable,
        lookup_params = {
            query = syllable,
            predictive = false,
            limit = 0
        }
    })
    end

    local lookup_result = AuxFilter.mem:dict_lookup(syllable, false, 0)
    local is_predictive = false

    if DEBUG_MODE then
    debug_log({
        event = "get_syllable_aux_set",
        step = "dict_lookup_result",
        syllable = syllable,
        lookup_result_type = type(lookup_result),
        lookup_result = lookup_result and "truthy" or "falsy",
        mode = "exact"
    })
    end

    local raw_aux_set, char_list, has_any, single_char_count

    if lookup_result then
        raw_aux_set, char_list, has_any, single_char_count = collect_aux_from_iter("exact")

        -- 精确匹配返回 truthy 但无单字结果 → fallback 到前缀匹配
        -- （有单字但无辅码说明音节范围正确，不需要 fallback）
        if single_char_count == 0 then
            if DEBUG_MODE then
            debug_log({
                event = "get_syllable_aux_set",
                step = "exact_no_single_char_fallback",
                syllable = syllable,
                reason = "exact match truthy but no single-char entries found"
            })
            end
            lookup_result = nil  -- 触发下方 fallback
        end
    end

    -- 第二步：精确匹配失败或无有效结果，尝试前缀匹配
    if not lookup_result then
        if DEBUG_MODE then
        debug_log({
            event = "get_syllable_aux_set",
            step = "try_predictive",
            syllable = syllable,
            mode = "predictive"
        })
        end

        lookup_result = AuxFilter.mem:dict_lookup(syllable, true, 0)
        is_predictive = true

        if DEBUG_MODE then
        debug_log({
            event = "get_syllable_aux_set",
            step = "predictive_result",
            syllable = syllable,
            lookup_result = lookup_result and "truthy" or "falsy",
            mode = "predictive"
        })
        end

        if lookup_result then
            raw_aux_set, char_list, has_any, single_char_count = collect_aux_from_iter("predictive")
        end
    end

    -- 两种匹配都失败
    if not lookup_result or not has_any then
        -- 仅精确匹配失败时缓存（前缀匹配结果不缓存，因为不同上下文可能不同）
        if not is_predictive then
            syllable_aux_cache[syllable] = false
        end
        if DEBUG_MODE then
        debug_log({
            event = "get_syllable_aux_set",
            step = "all_lookup_failed",
            syllable = syllable,
            status = "failed",
            reason = not lookup_result
                and "both exact and predictive lookup failed"
                or "no aux codes found in any mode"
        })
        end
        return nil
    end

    local expanded = {}
    local code_count = 0
    for key in pairs(raw_aux_set) do
        code_count = code_count + 1
        if AuxFilter.matchmode == 0 then
            expanded[key:sub(2, 2)] = true
        end
        expanded[key:sub(1, 1)] = true
        expanded[key] = true
    end

    -- 只缓存精确匹配的结果，前缀匹配结果不缓存
    if not is_predictive then
        syllable_aux_cache[syllable] = expanded
    end

    if DEBUG_MODE then
    debug_log({
        event = "get_syllable_aux_set",
        step = "success",
        syllable = syllable,
        status = "success",
        raw_code_count = code_count,
        char_count = #char_list,
        cached = not is_predictive
    })
    end

    return expanded
end

local function combmath(aux, fuset)
    if #aux == 0 then return true end
    if not fuset then return false end
    return fuset[aux] or (AuxFilter.matchmode == 0 and fuset[aux:reverse()])
end

local fullAuxCache = {}

local function main_main(env, cand)
    local S = AuxFilter.state
    local ftext = cand.text
    if cand:get_dynamic_type() == "Shadow" then
        ftext = cand:get_genuine().text
    end
    local auxCodes = AuxFilter.aux_code[ftext]
    -- 单字优先查预计算表（O(1)），多字词走按需计算缓存
    local fullAuxCodes = AuxFilter.fullAux_precomputed and AuxFilter.fullAux_precomputed[ftext]
    if not fullAuxCodes then
        fullAuxCodes = fullAuxCache[ftext]
        if not fullAuxCodes then
            fullAuxCodes = AuxFilter.fullAux(env, ftext)
            fullAuxCache[ftext] = fullAuxCodes
        end
    end
    local textLen = utf8len(ftext)
    if AuxFilter.show_aux_notice and auxCodes and #auxCodes > 0 then
        cand.comment = cand.comment .. '(' .. auxCodes .. ')'
    end
    if #(S.auxStr) ~= 2 then
        S.aux_left = nil
    end
    if #(S.auxStr) == 0 then
        cand = candisub:new(cand)
        AuxFilter.yield_candisub(cand)
    elseif #(S.auxStr) > 0 and fullAuxCodes and AuxFilter.match(fullAuxCodes, S.auxStr)
          and not (S.distraction and textLen == 2) then
        cand = candisub:new(cand)
        AuxFilter.yield_candisub(cand)
    elseif #(S.auxStr) == 2 and textLen == 2 then
        local firstchar = utf8sub(cand.text, 1, 1)
        local firsaux = S.auxStr:sub(1, 1)
        local firstchar_aux = AuxFilter.aux_code[firstchar]
        local first_bool = isCharInFirstPosition(firsaux, firstchar_aux)
        if not first_bool then return end
        local secondchar = utf8sub(cand.text, -1, -1)
        local secondaux = S.auxStr:sub(2, 2)
        local secondchar_aux = AuxFilter.aux_code[secondchar]
        local second_bool = isCharInFirstPosition(secondaux, secondchar_aux)
        
        -- 1. 主动分心模式：双码都匹配就直接输出，跳过去重逻辑
        if S.distraction and second_bool then
            S.one_aux_firstcode = S.one_aux_firstcode or ""
            if firstchar ~= S.one_aux_firstcode then return end
            cand.comment = "⇐" .. cand.comment
            cand = candisub:new(cand)
            AuxFilter.yield_candisub(cand)
            return
        end
        
        -- 2. 正常双码匹配处理（非主动分心）
        if not S.distraction and second_bool then
            S.one_aux_firstcode = S.one_aux_firstcode or ""
            if firstchar ~= S.one_aux_firstcode then return end
            if S.last_fist_commit[2] ~= cand.text then
                cand.comment = "**" .. cand.comment
                cand = candisub:new(cand)
                AuxFilter.yield_candisub(cand)
            end
        end

        if S.aux_left == "" then return end
        if S.counter ~= 0 then return end
        
        if firstchar == S.one_aux_firstcode then
            
            -- ==========================================
            -- 🚀 核心修复：前瞻探路 (Look-ahead Validation)
            -- 提前检查第二个音节(如 ji)的合法辅码集中，是否真的包含用户敲的辅码(如 f)
            -- ==========================================
            local preeditls = split_pinyin(cand.preedit)
            if preeditls and preeditls[2] then
                local fuset = get_syllable_aux_set(preeditls[2])
                if not combmath(secondaux, fuset) then
                    return -- 🚨 探路失败：死胡同，拒绝提供 *x 或 ✂ 虚假诱导，直接拦截！
                end
            end
            -- ==========================================

            S.aux_left = secondaux
            S.auxleftcandi = S.auxleftcandi or {}
            table.insert(S.auxleftcandi, cand)
        end
        return
    end
end

local function parseIntelligentCode(funccode)
    local result = {
        leftcompen = 0,
        rightcompen = 0,
        skipc = 0,
        dupc = 1,
        transor = false,
        trans_target = nil,
        rawor = false,
        raw_target = nil
    }
    if not funccode or funccode == "" then
        return result
    end
    local i = 1
    local n = #funccode
    while i <= n do
        local char = string.sub(funccode, i, i)
        if char == 'w' then
            result.skipc = result.skipc + 1
        elseif char == 'a' then
            result.leftcompen = result.leftcompen + 1
        elseif char == 's' then
            result.leftcompen = result.leftcompen + 2
        elseif char == 'd' then
            result.rightcompen = result.rightcompen + 1
        elseif char == 'f' then
            result.rightcompen = result.rightcompen + 2
        else
            break
        end
        i = i + 1
    end
    while i <= n do
        local guide_char = string.sub(funccode, i, i)
        if guide_char == 'c' then
            i = i + 1
            while i <= n do
                local op_char = string.sub(funccode, i, i)
                if op_char == 'c' then
                    result.dupc = result.dupc + 1
                elseif op_char == 'v' then
                    result.dupc = result.dupc * 2
                elseif op_char == 'b' then
                    result.dupc = result.dupc ^ 2
                elseif op_char == 'n' then
                    result.dupc = result.dupc - 1
                else
                    break
                end
                i = i + 1
            end
        elseif guide_char == 't' then
            i = i + 1
            result.transor = true
            if i + 1 <= n then
                result.trans_target = string.sub(funccode, i, i + 1)
                i = i + 2
            end
        elseif guide_char == 'r' then
            i = i + 1
            if i + 1 <= n then
                result.raw_target = string.sub(funccode, i, i + 1)
                result.rawor = true
                i = i + 2
            end
        else
            i = i + 1
        end
    end
    return result
end

local function normalize_string(str)
    if str == nil or str == "" then
        return ""
    end
    local result = {}
    for _, c in utf8.codes(str) do
        local ch = utf8.char(c)
        if c == 0x3000 then
            table.insert(result, " ")
        elseif c >= 0xFF01 and c <= 0xFF5E then
            table.insert(result, string.char(c - 0xFEE0))
        elseif ch:match("%u") then
            table.insert(result, ch:lower())
        else
            table.insert(result, ch)
        end
    end
    return table.concat(result)
end

function AuxFilter.main1(input, env)
    local S = AuxFilter.state
    local function process_input()
        S.auxStr, S.funccode = "", ""
        local localSplit = S.inputCode:match(AuxFilter.trigger_key_pattern .. "([^"..AuxFilter.trigger_key_pattern.."]+)")
        if localSplit then
            S.auxStr = string.sub(localSplit, 1, 2)
            S.funccode = string.sub(localSplit, #S.auxStr + 1)
            S.auxStr = S.auxStr:gsub(AuxFilter.ph_pattern, "")
            S.auxStr = normalize_string(S.auxStr)
            -- 主动分心：两位辅码后紧跟占位符逗号，强制跨字分配
            if #S.auxStr == 2 and S.funccode:sub(1, 1) == AuxFilter.ph then
                S.distraction = true
                S.funccode = S.funccode:sub(2)  -- 消费逗号，剩余传给功能码解析
            end
        end
        local result = parseIntelligentCode(S.funccode)
        S.leftcompen = result.leftcompen
        S.rightcompen = result.rightcompen
        S.skipc = result.skipc
        S.dupc = result.dupc
        S.transor = result.transor
        S.trans_target = result.trans_target
        S.rawor = result.rawor
        S.raw_target = result.raw_target
    end
    local function process_candidates()
        local firstcandi, rawpreedit
        local need_filter = S.single_flag
        for cand in input:iter() do
            if not need_filter or #split_pinyin(cand.preedit) == 1 then
                firstcandi, rawpreedit = cand, cand.preedit
                main_main(env, cand)
                break
            end
        end
        for cand in input:iter() do
            if not need_filter or #split_pinyin(cand.preedit) == 1 then
                main_main(env, cand)
            end
        end
        if not firstcandi then return nil, nil end
        local is_aux_str_len_two = (#(S.auxStr) == 2)
        local is_first_candi_not_single_char = (utf8len(firstcandi.text) ~= 1)
        
        -- 提取遗留辅码
        if S.distraction then
            S.aux_left = S.auxStr:sub(2, 2)
        end

        -- 统一处理收集到的截断候选词（同时支持主动与被动分心）
        if is_aux_str_len_two and is_first_candi_not_single_char then
            if S.counter > 0 then
                if not S.distraction then 
                    S.aux_left = "" 
                end
            elseif S.counter == 0 then
                S.auxleftcandi = S.auxleftcandi or {}
                for _, v in ipairs(S.auxleftcandi) do
                    -- 主动分心用 ✂ 标记，被动潜在分心用 *x 标记
                    v.comment = (S.distraction and "✂ " or "*x") .. (v.comment or "")
                    v = candisub:new(v, 1)
                    AuxFilter.yield_candisub(v)
                end
            end
        end
        S.auxleftcandi = nil
        return firstcandi, rawpreedit
    end
    local function handle_no_match(firstcandi, rawpreedit)
        if not firstcandi then return end
        local inputspls = split_pinyin(rawpreedit)
        firstcandi.preedit = rawpreedit
        local cand = candisub:new(firstcandi)
        -- 使用 utf8.codes 线性迭代，避免 utf8sub 内部重复 offset 扫描的 O(N²)
        local candtext_list = {}
        for _, c in utf8.codes(cand.cand.text) do
            candtext_list[#candtext_list + 1] = utf8.char(c)
        end
        if AuxFilter.longcandimodify_flag and (not S.single_flag) and cand.line then
            local matchybtab = {}
            for index, value in ipairs(inputspls) do
                local fuset = get_syllable_aux_set(value)
                if combmath(S.auxStr, fuset) then
                    table.insert(matchybtab, index .. "." .. candtext_list[index])
                    candtext_list[index] = "<" .. candtext_list[index]
                end
            end
            if #matchybtab == 0 then
                candtext_list[1] = "❗" .. candtext_list[1]
            end
        elseif AuxFilter.longcandimodify_flag and S.single_flag and cand.line then
            candtext_list[1] = "❗" .. candtext_list[1]
        end
        cand.cand = Candidate(cand.cand.type, cand.cand._start, cand.cand._end, table.concat(candtext_list), cand.cand.comment)
        yield(cand.cand)
    end
    process_input()
    if not S.transor and not S.rawor then
        S.transedtext = nil
    end
    S.counter = 0
    local firstcandi, rawpreedit = process_candidates()
    S.turned = false
    if S.counter == 0 then
        handle_no_match(firstcandi, rawpreedit)
    end
end

function AuxFilter.defaultmain(input, env)
    for cand in input:iter() do
        AuxFilter.yield_candisub(candisub:new(cand))
    end
end

-- ============================================
-- V2 修复：longcandimodify 修音崩溃修复
-- ============================================
function AuxFilter.longcandimodify(input, env)
    local S = AuxFilter.state
    local branchmark = 1
    S.notifiermark = 2

    if DEBUG_MODE then
    debug_log({
        event = "longcandimodify_start",
        inputCode = S.inputCode,
        precode = S.precode
    })
    end

    local function get_first_candidate()
        for cand in input:iter() do
            S.ftext = (cand.type == "Shadow" or cand.type == "simplified")
                     and cand:get_genuine().text or cand.text

            if DEBUG_MODE then
            debug_log({
                event = "get_first_candidate",
                step = "found",
                cand_text = cand.text,
                cand_type = cand.type,
                cand_preedit = cand.preedit,
                ftext = S.ftext
            })
            end

            return cand
        end
    end

    local function parse_input_code()
        local auxcode = S.inputCode:match(AuxFilter.trigger_key_pattern .. "(%a*)" .. AuxFilter.trigger_key_pattern)
        local funccode = S.inputCode:match(AuxFilter.trigger_key_pattern .. "%a*" .. AuxFilter.trigger_key_pattern .. "+(%a*)")
        local ybmodif = funccode and funccode:match("s(%a+)")

        if ybmodif then
            branchmark = 2
            funccode = string.gsub(funccode, "s" .. ybmodif, "")
        end

        if DEBUG_MODE then
        debug_log({
            event = "parse_input_code",
            auxcode = auxcode or "",
            funccode = funccode or "",
            ybmodif = ybmodif or "",
            branchmark = branchmark
        })
        end

        return auxcode, funccode, ybmodif
    end

    local function process_offsets(firstcandi, funccode)
        S.leftcompen = countSubstringOccurrences(funccode or "", "a")
        S.rightcompen = countSubstringOccurrences(funccode or "", "d") +
                       2 * countSubstringOccurrences(funccode or "", "f")

        local inputspls = split_pinyin(firstcandi.preedit)
        S.ficompensate = utf8len(firstcandi.text)

        if DEBUG_MODE then
        debug_log({
            event = "process_offsets",
            leftcompen = S.leftcompen,
            rightcompen = S.rightcompen,
            preedit = firstcandi.preedit,
            inputspls = inputspls,
            ficompensate_initial = S.ficompensate
        })
        end

        return inputspls
    end

    local function find_break_point(inputspls, auxcode)
        local passnum = countSubstringOccurrences(S.inputCode, AuxFilter.trigger_key) - 2
        local matchedmark = false

        if DEBUG_MODE then
        debug_log({
            event = "find_break_point_start",
            auxcode = auxcode or "",
            passnum = passnum,
            inputCode = S.inputCode,
            trigger_key = AuxFilter.trigger_key
        })
        end

        local match_results = {}

        for index, value in ipairs(inputspls) do
            local zi = utf8sub(S.ftext, index, index)

            if DEBUG_MODE then
            debug_log({
                event = "find_break_point_loop",
                step = "iteration_start",
                index = index,
                value = value,
                zi = zi
            })
            end

            local fuset = get_syllable_aux_set(value)

            -- 详细记录 fuset 内容
            local fuset_keys
            if DEBUG_MODE then
                fuset_keys = {}
                if fuset then
                    for k in pairs(fuset) do fuset_keys[#fuset_keys + 1] = k end
                    table.sort(fuset_keys)
                end
            end

            if DEBUG_MODE then
            debug_log({
                event = "find_break_point_loop",
                step = "fuset_detail",
                index = index,
                syllable = value,
                zi = zi,
                fuset_exists = fuset ~= nil,
                fuset_keys = fuset_keys,
                fuset_size = fuset and #fuset_keys or 0
            })
            end

            local matched = combmath(auxcode, fuset)

            if DEBUG_MODE then
            debug_log({
                event = "find_break_point_loop",
                step = "combmath_check",
                index = index,
                syllable = value,
                auxcode = auxcode or "",
                fuset_exists = fuset ~= nil,
                matched = matched,
                combmath_detail = fuset
                    and ("fuset[" .. auxcode .. "] = " .. tostring(fuset[auxcode]))
                    or "fuset is nil"
            })
            end

            if DEBUG_MODE then
            table.insert(match_results, {
                index = index,
                syllable = value,
                zi = zi,
                fuset_exists = fuset ~= nil,
                matched = matched
            })
            end

            if DEBUG_MODE then
            debug_log({
                event = "find_break_point_loop",
                step = "match_result",
                index = index,
                syllable = value,
                zi = zi,
                auxcode = auxcode or "",
                matched = matched,
                final_ficompensate = matched and index or nil,
                matchedmark_will_be = matched and true or matchedmark
            })
            end

            if matched then
                S.ficompensate = index
                matchedmark = true
                if passnum == 0 then
                    if DEBUG_MODE then
                    debug_log({
                        event = "find_break_point_loop",
                        step = "break_early",
                        index = index,
                        reason = "passnum_reached_zero"
                    })
                    end
                    break
                end
                passnum = passnum - 1
            end
        end

        if matchedmark then
            S.ficompensate = S.ficompensate - 1
        end

        if DEBUG_MODE then
        debug_log({
            event = "find_break_point_end",
            matchedmark = matchedmark,
            ficompensate = S.ficompensate,
            match_results = match_results
        })
        end

        return matchedmark
    end

    local firstcandi = get_first_candidate()
    if not firstcandi then
        if DEBUG_MODE then
        debug_log({
            event = "longcandimodify_end",
            status = "no_candidate"
        })
        end
        return
    end

    local auxcode, funccode, ybmodif = parse_input_code()
    local inputspls = process_offsets(firstcandi, funccode)
    local matchedmark = find_break_point(inputspls, auxcode)

    -- ========================================
    -- V2 修复：修音分支
    -- ========================================
    if branchmark == 2 then
        S.notifiermark = 3

        -- [V2 FIX] 不直接修改 inputspls，而是从原始 preedit 创建新数组
        -- 原因: inputspls 可能是 split_pinyin 的缓存数组，
        --       直接修改会污染缓存，导致下一轮崩溃
        local fresh_spls = {}
        for i, v in ipairs(inputspls) do
            fresh_spls[i] = v
        end

        local target_idx = S.ficompensate + 1

        if DEBUG_MODE then
        debug_log({
            event = "longcandimodify_branch",
            branch = "ybmodify",
            fix_applied = "fresh_spls_copy",
            target_idx = target_idx,
            ybmodif = ybmodif
        })
        end

        -- [V2 FIX] 增加越界安全检查，防止崩溃
        if target_idx < 1 or target_idx > #fresh_spls then
            if DEBUG_MODE then
            debug_log({
                event = "longcandimodify_branch",
                branch = "ybmodify_error",
                error = "target_idx_out_of_bounds",
                target_idx = target_idx,
                inputspls_length = #fresh_spls
            })
            end

            yield(Candidate(firstcandi.type, firstcandi._start, firstcandi._start,
                "", "修音失败：断点越界"))
            return
        end

        local wrongyb = fresh_spls[target_idx]
        fresh_spls[target_idx] = ybmodif
        local inputcode2 = table.concat(fresh_spls, "")
        S.ybmodifiedcode = S.transdcodei .. inputcode2 .. AuxFilter.trigger_key
        S.removetransdInput = inputcode2:sub(1, -2)

        if DEBUG_MODE then
        debug_log({
            event = "longcandimodify_branch",
            branch = "ybmodify_success",
            wrongyb = wrongyb,
            ybmodif = ybmodif,
            ficompensate = S.ficompensate,
            fresh_spls = fresh_spls,
            ybmodifiedcode = S.ybmodifiedcode
        })
        end

        yield(Candidate(firstcandi.type, firstcandi._start, firstcandi._start, "", wrongyb .. "->" .. ybmodif))

    elseif branchmark == 1 then
        local finalcandi = candisub:new(firstcandi, S.ficompensate)
        finalcandi.comment = matchedmark and "" or "辅码无匹配"

        if DEBUG_MODE then
        debug_log({
            event = "longcandimodify_branch",
            branch = "break",
            matchedmark = matchedmark,
            ficompensate = S.ficompensate,
            final_text = finalcandi.cand.text,
            final_comment = finalcandi.comment
        })
        end

        AuxFilter.yield_candisub(finalcandi)
    end

    if DEBUG_MODE then
    debug_log({
        event = "longcandimodify_end",
        status = "completed"
    })
    end
end

local function transform_input_code(inputcode)
    -- 使用 init 阶段预编译的 pattern，避免每次按键动态拼接正则
    local pattern = AuxFilter.pattern_transform
    if inputcode:match(pattern) then
        return inputcode:gsub(pattern, AuxFilter.repl_transform)
    else
        return inputcode
    end
end

function AuxFilter.Update_codes(ctx)
    local S = AuxFilter.state
    local context = ctx
    S.inputCode = context.input
    S.inputCode = transform_input_code(S.inputCode)
    S.precode = context:get_preedit().text
    S.precode = transform_input_code(S.precode)
    S.removeAuxInput = S.inputCode:match(AuxFilter.pattern_removeAux) or ""
    S.removeAuxprecode = S.precode:match(AuxFilter.pattern_removeAux) or ""
    S.removetransdInput = S.removeAuxprecode:match(AuxFilter.pattern_removetransd) or ""
    local pos1 = S.removeAuxprecode:find(S.removetransdInput, 1, true)
    if pos1 and S.removetransdInput ~= "" then
        S.transdcode = S.removeAuxprecode:sub(1, pos1 - 1) .. S.removeAuxprecode:sub(pos1 + #S.removetransdInput)
    else
        S.transdcode = S.removeAuxprecode
    end
    local pos2 = S.removeAuxInput:find(S.removetransdInput, 1, true)
    if pos2 and S.removetransdInput ~= "" then
        S.transdcodei = S.removeAuxInput:sub(1, pos2 - 1) .. S.removeAuxInput:sub(pos2 + #S.removetransdInput)
    else
        S.transdcodei = S.removeAuxInput
    end
end

local function switch_single_char(ctx)
    local S = AuxFilter.state
    S.single_flag = not S.single_flag
    S.turned = true
    ctx.input = ctx.input:gsub(AuxFilter.switch_key .. "$", "")
    AuxFilter.Update_codes(ctx)
end

function AuxFilter.func(input, env)
    AuxFilter.env = env
    if not AuxFilter.state then
        AuxFilter.state = {
            single_flag = false,
            turned = false,
            last_fist_commit = nil,
            transedtext = nil,
        }
    end
    local S = AuxFilter.state
    S.notifiermark = -1
    S.yieldset = clear_table(S.yieldset)
    S.yieldrawset = clear_table(S.yieldrawset)
    S.leftcompen = 0
    S.rightcompen = 0
    S.skipc = 0
    S.counter = 0
    S.prelen = nil
    S.dupc = 1
    S.transor = false
    S.trans_target = nil
    S.rawor = false
    S.raw_target = nil
    S.auxStr = ""
    S.funccode = ""
    S.distraction = false
    S.auxleftcandi = nil
    S.firstcand_len = nil
    S.ficompensate = nil
    S.ftext = nil
    S.inputCode = ""
    S.precode = ""
    S.removeAuxInput = ""
    S.removeAuxprecode = ""
    S.removetransdInput = ""
    S.transdcode = ""
    S.transdcodei = ""

    local ctx = env.engine.context
    AuxFilter.Update_codes(ctx)

    if DEBUG_MODE then
    debug_log({
        event = "func_dispatch",
        inputCode = S.inputCode,
        precode = S.precode,
        pattern_main1 = AuxFilter.pattern_main1,
        pattern_long = AuxFilter.pattern_long
    })
    end

    if string.match(S.inputCode, AuxFilter.pattern_main1) then
        local composition = env.engine.context.composition
        if(not composition:empty()) then
            local segment = composition:back()
            if S.single_flag then
                segment.prompt = "单字筛选分支"
            end
        end
        S.notifiermark = 1
        AuxFilter.main1(input,env)
    elseif string.match(S.inputCode, AuxFilter.pattern_singlechar_switch) then
        switch_single_char(env.engine.context)
        S.notifiermark = 1
        AuxFilter.main1(input,env)
    elseif string.match(S.inputCode, AuxFilter.pattern_long) then
        S.last_fist_commit = nil
        S.transedtext = nil

        if DEBUG_MODE then
        debug_log({
            event = "func_dispatch",
            branch = "longcandimodify",
            inputCode = S.inputCode
        })
        end

        AuxFilter.longcandimodify(input,env)
    else
        S.last_fist_commit = nil
        S.transedtext = nil
        AuxFilter.defaultmain(input,env)
    end
end

function AuxFilter.fini(env)
    env.notifier:disconnect()
    if env.update_notifier then
        env.update_notifier:disconnect()
    end
    if debugfile then
        debugfile:close()
    end
end

return AuxFilter
