# vim:set ft= ts=4 sw=4 et fdm=marker:

use Test::Nginx::Socket::Lua;
use Cwd qw(cwd);

repeat_each(2);

plan tests => repeat_each() * (blocks() * 4);

worker_connections(1024);
#no_diff();
#no_long_string();

my $pwd = cwd();

our $HttpConfig = <<_EOC_;
    lua_package_path "$pwd/lib/?.lua;;";
_EOC_

no_long_string();
run_tests();

__DATA__

=== TEST 1: a single key
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            ngx.shared.store:flush_all()

            local limit_rate = require "resty.limit.rate"
            local lim = limit_rate.new("store", 10, 10, 1)
            local key = "foo"
            lim:sending(key, 0)
            for i = 0, 8 do
                local ok, err = lim:incoming(key)
                if not ok then
                    ngx.say("failed to limit rate: ", err)
                else
                    local excess = err
                    ngx.say(i, ": ", ok, ", excess: ", excess)
                end

                lim:sending(key, 3)
            end
        ';
    }
--- request
    GET /t
--- response_body
0: 0, excess: 0
1: 0, excess: 0
2: 0, excess: 0
3: 0, excess: 0
4: 0, excess: 2
5: 0, excess: 5
6: 0, excess: 8
failed to limit rate: rejected
failed to limit rate: rejected
--- no_error_log
[error]
[lua]



=== TEST 2: a single key (always commit)
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua '
            ngx.shared.store:flush_all()

            local limit_rate = require "resty.limit.rate"
            local lim = limit_rate.new("store", 80, 20, 1)
            local uri = ngx.var.uri
            lim:sending(uri, 0)
            local begin = ngx.now()
            local rejected = 0
            for i = 0, 80 do
                local ok, err = lim:incoming(uri)
                if not ok then
                    rejected = rejected + 1
                else
                    lim:sending(uri, 2)
                end
            end
            ngx.say("rejected: ", rejected)
        ';
    }
--- request
    GET /t
--- response_body
rejected: 30
--- no_error_log
[error]
[lua]



=== TEST 3: http_simulate
--- http_config eval
"
$::HttpConfig

    lua_shared_dict store 1m;
"
--- config
    location = /t {
        content_by_lua_block {
            local rejected = 0

            local function http_simulate(i)
                local limit_rate = require "resty.limit.rate"
                local lim = limit_rate.new("store", 10000, 1000, 0.01)

                local key = "foo"
                local ok, err = lim:incoming(key)
                if not ok then
                    rejected = rejected + 1
                    return
                end

                -- ngx.say("i: ", i)
                ngx.sleep(0.01)

                -- 20 bytes per request
                lim:sending(key, 200)
            end

            ngx.shared.store:flush_all()

            local th
            for i = 1, 100 do
                th = ngx.thread.spawn(http_simulate, i)
                ngx.sleep(0.01) -- 20000 bytes per second
            end

            -- wait the last one
            ngx.thread.wait(th)

            ngx.say("rejected: ", rejected)
        }
    }
--- timeout
10s
--- request
    GET /t
--- response_body_like
rejected: 4[01]
--- no_error_log
[error]
[lua]
