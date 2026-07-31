# `token@1.0`

## build and verify

```sh
rebar3 compile
rebar3 device verify
rebar3 device package
```

## test

```sh
HB_PORT=0 rebar3 device test
rebar3 eunit-all
```
## published package

```bash
device publish: token@1.0 

spec=7LWK7RCyMKCZ1uiANJ5At1vfsiwra1T_5xkBG3X_so0

impl=TmTc-Tjo8WWrp6Th8Kgqs7azjIKHgyNIcvZ6NW-zvps

signer=eFNj8Xo_fbPWkEFL47YgEHctsxs03jk6fSGDr_xTiFY
```
## local node

```sh
HB_CONFIG=config.json rebar3 device local
```

`config.json` pins the published `process-outbox@1.0` and `security@1.0` implementations through
HyperBEAM's `trusted-devices` runtime map.

src:

* https://github.com/permaweb/process-outbox-1.0
* https://github.com/permaweb/security-1.0

```json
{
  "trusted-devices": {
    "process-outbox@1.0": "HOcPV7wxMHYb3rSQ3EfykQhHx_b8waRWhXolhcBNgHo",
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

## publish

```sh
rebar3 device publish --key wallet.json
```

## License
this package is licensed under the [MIT License](./LICENSE)
