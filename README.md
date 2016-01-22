# eSIP

[![Build Status](https://travis-ci.org/processone/esip.svg?branch=master)](https://travis-ci.org/processone/esip) [![Coverage Status](https://coveralls.io/repos/processone/esip/badge.svg?branch=master&service=github)](https://coveralls.io/github/processone/esip?branch=master) [![Hex version](https://img.shields.io/hexpm/v/esip.svg "Hex version")](https://hex.pm/packages/esip)


ProcessOne SIP server component in Erlang.

## Building

Erlang SIP component can be build as follow:

    ./configure && make

It is a rebar-compatible OTP application. Alternatively, you can build
it with rebar:

    rebar compile

## Dependencies

Module depends on fast_tls and as such you need to have OpenSSL 1.0+.

Please refer to fast_tls build instruction is you need help setting
your OpenSSL environment:
[Building Fast TLS](https://github.com/processone/fast_tls/blob/master/README.md#generic-build)

## Development

### Test

#### Unit test

You can run eunit test with the command:

    $ rebar eunit
