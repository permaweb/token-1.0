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
rebar3 device local
```

## Publish

```sh
rebar3 device publish --key wallet.json
```
