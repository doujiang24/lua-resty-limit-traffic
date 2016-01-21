
local ffi = require "ffi"
local math = require "math"


local ngx_shared = ngx.shared
local ngx_now = ngx.now
local setmetatable = setmetatable
local ffi_cast = ffi.cast
local ffi_str = ffi.string
local abs = math.abs
local tonumber = tonumber
local type = type
local assert = assert


-- TODO: we could avoid the tricky FFI cdata when lua_shared_dict supports
-- hash-typed values as in redis.
ffi.cdef[[
    struct lua_resty_limit_rate_rec {
        uint64_t            excess;
        uint64_t            last;  /* time in milliseconds */
        /* integer value, 1 corresponds to 0.001 byte/s */
    };
]]
local const_rec_ptr_type = ffi.typeof("const struct lua_resty_limit_rate_rec*")
local rec_size = ffi.sizeof("struct lua_resty_limit_rate_rec")

-- we can share the cdata here since we only need it temporarily for
-- serialization inside the shared dict:
local rec_cdata = ffi.new("struct lua_resty_limit_rate_rec")


local _M = {
    _VERSION = '0.01'
}


local mt = {
    __index = _M
}


function _M.new(dict_name, rate, burst, default_delay)
    local dict = ngx_shared[dict_name]
    if not dict then
        return nil, "shared dict not found"
    end

    assert(rate > 0 and burst >= 0)

    local self = {
        dict = dict,
        rate = rate * 1000,
        burst = burst * 1000,
        unit_delay = default_delay * 1000,
    }

    return setmetatable(self, mt)
end


-- sees an new incoming event
function _M.incoming(self, key)
    local dict = self.dict
    local rate = self.rate
    local now = ngx_now() * 1000

    local excess

    -- it's important to anchor the string value for the read-only pointer
    -- cdata:
    local v = dict:get(key)
    if v then
        if type(v) ~= "string" or #v ~= rec_size then
            return nil, "shdict abused by other users"
        end
        local rec = ffi_cast(const_rec_ptr_type, v)
        local elapsed = now - tonumber(rec.last)

        -- print("elapsed: ", elapsed, "ms")

        -- we do not handle changing rate values specifically. the excess value
        -- can get automatically adjusted by the following formula with new rate
        -- values rather quickly anyway.
        excess = tonumber(rec.excess)
                 - rate * (abs(elapsed) + self.unit_delay) / 1000

        if excess < 0 then
            -- ngx.log(ngx.WARN, "excess: ", excess / 1000)
            excess = 0
        end

        -- print("excess: ", excess)

        if excess > self.burst then
            return nil, "rejected"
        end

    else
        excess = 0
    end

    -- always 0 delay
    return 0, excess / 1000
end


-- FIXME we have a (small) race-condition window between dict:get() and
-- dict:set() across multiple nginx worker processes. The size of the
-- window is proportional to the number of workers.
function _M.sending(self, key, bytes, req_latency)
    local dict = self.dict
    local rate = self.rate
    local now = ngx_now() * 1000

    local excess

    -- it's important to anchor the string value for the read-only pointer
    -- cdata:
    local v = dict:get(key)
    if v then
        if type(v) ~= "string" or #v ~= rec_size then
            return nil, "shdict abused by other users"
        end
        local rec = ffi_cast(const_rec_ptr_type, v)
        local elapsed = now - tonumber(rec.last)

        -- print("elapsed: ", elapsed, "ms")

        -- we do not handle changing rate values specifically. the excess value
        -- can get automatically adjusted by the following formula with new rate
        -- values rather quickly anyway.
        excess = tonumber(rec.excess)
                 - rate * abs(elapsed) / 1000 + bytes * 1000

        if excess < 0 then
            -- ngx.log(ngx.WARN, "excess: ", excess / 1000)
            excess = 0
        end

    else
        excess = 0
    end

    rec_cdata.excess = excess
    rec_cdata.last = now
    dict:set(key, ffi_str(rec_cdata, rec_size))

    if req_latency then
        self.unit_delay = (self.unit_delay * 99 + req_latency) / 100
    end
end


-- only used for resty.limit.traffic
function _M.uncommit(self, key)
    return true
end


function _M.set_rate(self, rate)
    self.rate = rate * 1000
end


function _M.set_burst(self, burst)
    self.burst = burst * 1000
end


return _M
