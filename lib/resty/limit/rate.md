Name
====

resty.limit.rate - Lua module for limiting rate for OpenResty/ngx_lua.

Table of Contents
=================

* [Name](#name)
* [Synopsis](#synopsis)
* [Description](#description)
* [Methods](#methods)
    * [new](#new)
    * [incoming](#incoming)
    * [leaving](#leaving)
    * [set_rate](#set_rate)
    * [set_burst](#set_burst)
    * [uncommit](#uncommit)
* [Caveats](#caveats)
* [Instance Sharing](#instance-sharing)
* [Installation](#installation)
* [See Also](#see-also)

Synopsis
========

```nginx
# demonstrate the usage of the resty.limit.rate module (alone!)
http {
    lua_shared_dict my_limit_rate_store 100m;

    server {
        location / {
            access_by_lua_block {
                -- well, we could put the require() and new() calls in our own Lua
                -- modules to save overhead. here we put them below just for
                -- convenience.

                local limit_rate  = require "resty.limit.rate"

                -- limit the rate under 2000 bytes/s with
                -- a burst of 200 bytes/s extra rate, that is, we
                -- reject any new requests exceeding 2200 bytes/s
                local lim, err = limit_rate.new("my_limit_rate_store", 2000, 200, 0.1)
                if not lim then
                    ngx.log(ngx.ERR,
                            "failed to instantiate a resty.limit.rate object: ", err)
                    return ngx.exit(500)
                end

                -- the following call must be per-request.
                -- here we use the uri as the limiting key
                local key = ngx.var.uri
                local delay, err = lim:incoming(key)
                if not delay then
                    return ngx.exit(503)
                end

                local ctx = ngx.ctx
                ctx.limit_rate = lim
                ctx.limit_rate_key = key
                ctx.limit_start_time = ngx.now()

                -- delay always be 0
                -- the 2nd return value holds the current excess
                -- for the specified key.
                local excess = err
            }

            # content handler goes here.

            # body_filter_by_lua_block (for long time request) or log_by_lua_block choose one

            body_filter_by_lua_block {
                local ctx = ngx.ctx
                local lim = ctx.limit_rate
                if lim then
                    local latency
                    if ctx.limit_start_time then
                        latency = tonumber(ngx.now() - ctx.limit_start_time)
                        ctx.limit_start_time = nil
                    end
                    local bytes = #ngx.arg[1]
                    local key = ctx.limit_rate_key
                    assert(key)
                    lim:leaving(key, bytes, latency)
                end
            }

            log_by_lua_block {
                local ctx = ngx.ctx
                local lim = ctx.limit_rate
                if lim then
                    -- or just use ngx.var.request_time instead
                    local latency = tonumber(ngx.now() - ctx.limit_start_time)
                    local bytes = tonumber(ngx.var.bytes_sent)
                    local key = ctx.limit_rate_key
                    assert(key)
                    lim:leaving(key, bytes, latency)
                end
            }
        }
    }
}
```

Description
===========

This module provides APIs to help the OpenResty/ngx_lua user programmers limit rate.

If you want to use multiple different instances of this class at once or use one instance
of this class with instances of other classes (like [resty.limit.req](./req.md)),
then you *must* use the [resty.limit.traffic](./traffic.md) module to combine them.

In contrast with NGINX's standard
[limit_rate](http://nginx.org/en/docs/http/ngx_http_core_module.html#limit_rate) command,
this Lua module supports limit on any key.

Methods
=======

[Back to TOC](#table-of-contents)

new
---
**syntax:** `obj, err = class.new(shdict_name, rate, burst, default_delay)`

Instantiates an object of this class. The `class` value is returned by the call `require "resty.limit.rate"`.

This method takes the following arguments:

* `shdict_name` is the name of the
[lua_shared_dict](https://github.com/openresty/lua-nginx-module#lua_shared_dict) shm zone.

    It is best to use separate shm zones for different kinds of limiters.
* `rate` is the maximum rate allowed. Rate exceeding this ratio (and below `rate` + `burst`)
won't be rejected.
* `burst` is the number of excessive rate allowed to be rejected.

    Requests exceeding this hard limit should get rejected immediately.
* `default_delay` is the default processing latency of a typical request (`request_time` for `log_by_lua`, time from request started to first byte send to client for `body_filter_by_lua`).

On failure, this method returns `nil` and a string describing the error (like a bad `lua_shared_dict` name).

[Back to TOC](#table-of-contents)

incoming
--------
**syntax:** `delay, err = obj:incoming(key)`

[Back to TOC](#table-of-contents)

leaving
--------
**syntax:** `obj:leaving(key, bytes, req_latency)`

[Back to TOC](#table-of-contents)

set_rate
--------
**syntax:** `obj:set_rate(rate)`

Overwrites the `rate` threshold value as specified in the [new](#new) method.

[Back to TOC](#table-of-contents)

set_burst
---------
**syntax:** `obj:set_burst(burst)`

Overwrites the `burst` threshold value as specified in the [new](#new) method.

[Back to TOC](#table-of-contents)

uncommit
--------
**syntax:** `ok, err = obj:uncommit(key)`

Always return true.

[Back to TOC](#table-of-contents)

Caveats
========

[Back to TOC](#table-of-contents)

Instance Sharing
================

Each instance of this class carries no state information but the `rate` and `burst`
threshold values. The real limiting states based on keys are stored in the `lua_shared_dict`
shm zone specified in the [new](#new) method. So it is safe to share instances of
this class [on the nginx worker process level](https://github.com/openresty/lua-nginx-module#data-sharing-within-an-nginx-worker)
as long as the combination of `rate` and `burst` do not change.

Even if the `rate` and `burst`
combination *does* change, one can still share a single instance as long as he always
calls the [set_rate](#set_rate) and/or [set_burst](#set_burst) methods *right before*
the [incoming](#incoming) call.

[Back to TOC](#table-of-contents)

Installation
============

Please see [library installation instructions](../../../README.md#installation).

[Back to TOC](#table-of-contents)

See Also
========
* module [resty.limit.req](./req.md)
* module [resty.limit.traffic](./traffic.md)
* library [lua-resty-limit-traffic](../../../README.md)
* the ngx_lua module: https://github.com/openresty/lua-nginx-module
* OpenResty: http://openresty.org

[Back to TOC](#table-of-contents)

