# `token_package`

HyperBEAM Forge package for AO token-family devices. The package root devices
are:

- `security@1.0`: security normalization and authority checks for process
  assignments.
- `token@1.0`: AO token process execution, transfers, subscriptions, and mint
  delegation.

## Build And Verify

```sh
rebar3 compile
rebar3 device verify
rebar3 device package
```

## Test

```sh
HB_PORT=0 rebar3 device test
rebar3 eunit-all
```

## Local Node

```sh
HB_CONFIG=config.json rebar3 device local
```

`config.json` pins the published `process-outbox@1.0` implementation through
HyperBEAM's `trusted-devices` runtime map.

src: https://github.com/permaweb/process-outbox

## Publish

```sh
rebar3 device publish --key wallet.json
```
