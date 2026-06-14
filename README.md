# `token@1.0`

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
## published package

```bash
device publish: token@1.0 

spec=LG06XpaM8FqTD80TLJ2gYTybGuW8tdQsk0WcTWMBa84 

impl=rRDu38GMdk7Tv9CLMuM3lpm06kH_NvMuwwbcM-zNlRc 

signer=vZY2XY1RD9HIfWi8ift-1_DnHLDadZMWrufSh-_rKF0
```
## Local Node

```sh
HB_CONFIG=config.json rebar3 device local
```

`config.json` pins the published `process-outbox@1.0` and `security@1.0` implementations through
HyperBEAM's `trusted-devices` runtime map.

src:

* https://github.com/permaweb/process-outbox
* https://github.com/permaweb/security-1.0

```json
{
  "trusted-devices": {
    "process-outbox@1.0": "IgFctN6dNiwIoQrONi__4trJ70bkamBXXp9ipyW3SQI",
    "security@1.0": "ARgymad5oYZcWPpxuV-A9hoSgmm4ElgPIvxMwmeh674"
  }
}
```

## interaction with deployed token

use the process path for token semantics. this gives `process@1.0` a chance to
load the current state, run `token@1.0/init` if needed, and then switch into the
execution device:

```bash
GET /<token-id>/now/as/balance?as=execution&balance=<address>
GET /<token-id>/now
POST /<token-id>/schedule
```

raw state paths are only for inspection:

```bash
GET /<token-id>/balances/<exact-raw-key>
GET /<token-id>/now/balances/<canonical-key>
```

dont use `/<token-id>~token@1.0/balance?...` as the normal client path. That
calls the token device against the raw published item and bypasses
`process@1.0` initialization/caching.

## Publish

```sh
rebar3 device publish --key wallet.json
```
