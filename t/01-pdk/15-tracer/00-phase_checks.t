use strict;
use warnings FATAL => 'all';
use Test::Nginx::Socket::Lua;
do "./t/Util.pm";

$ENV{TEST_NGINX_NXSOCK}   ||= html_dir();

plan tests => repeat_each() * (blocks() * 2);

run_tests();

__DATA__

=== TEST 1: verify phase checking in kong.tracer
--- http_config eval
qq{
    $t::Util::HttpConfig

    server {
        listen unix:$ENV{TEST_NGINX_NXSOCK}/nginx.sock;

        location / {
            set \$upstream_uri '/t';
            set \$upstream_scheme 'http';

            rewrite_by_lua_block {
                phase_check_functions(phases.rewrite, true)
            }

            access_by_lua_block {
                phase_check_functions(phases.access, true)
                phase_check_functions(phases.response, true)
                phase_check_functions(phases.admin_api, true)
            }

            header_filter_by_lua_block {
                phase_check_functions(phases.header_filter, true)
            }

            body_filter_by_lua_block {
                phase_check_functions(phases.body_filter, true)
            }

            log_by_lua_block {
                phase_check_functions(phases.log, true)
            }

            return 200;
        }
    }

    init_worker_by_lua_block {
        phases = require("kong.pdk.private.phases").phases

        phase_check_module = "tracer"
        phase_check_data = {
            {
                method        = "new",
                args          = {"tracer"},
                init_worker   = false,
                certificate   = false,
                rewrite       = true,
                access        = true,
                header_filter = true,
                response      = true,
                body_filter   = true,
                log           = true,
                admin_api     = true,
            }, {
                method        = "start_span",
                args          = {"span_name"},
                init_worker   = false,
                certificate   = false,
                rewrite       = true,
                access        = true,
                header_filter = true,
                response      = true,
                body_filter   = true,
                log           = true,
                admin_api     = true,
            }, {
                method        = "active_span",
                args          = {},
                init_worker   = false,
                certificate   = false,
                rewrite       = true,
                access        = true,
                header_filter = true,
                response      = true,
                body_filter   = true,
                log           = true,
                admin_api     = true,
            }, {
                method        = "set_active_span",
                args          = {},
                init_worker   = false,
                certificate   = false,
                rewrite       = true,
                access        = true,
                header_filter = true,
                response      = true,
                body_filter   = true,
                log           = true,
                admin_api     = true,
            },
        }

        phase_check_functions(phases.init_worker, true)
    }
}
--- config
    location /t {
        proxy_pass http://unix:$TEST_NGINX_NXSOCK/nginx.sock;
    }
--- request
GET /t
--- no_error_log
[error]
