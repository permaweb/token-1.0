# `token@1.0`

## build and verify

```sh
rebar3 compile
rebar3 device verify --device-src=src,_build/default/lib/hb/src/preloaded/token
rebar3 device package --device-src=src,_build/default/lib/hb/src/preloaded/token
```

## test

```sh
HB_PORT=0 rebar3 device test
rebar3 eunit-all
```

## genesis

Initialization requires valid addresses with non-negative integer balances and a
non-negative `total-supply` equal to their sum. Invalid genesis state fails closed.

## published package

```bash
Published device: token@1.0; 

Specification ID: KHSPOf6n-B6EXKF-9adTYzo6S_Sl3_GY1Qy0f4sL_QQ; 

Implementation ID: mwLP8r5OobCcudFPJJeRs6XepmkoZy5ZW9R8BXs3bFg; 

Signer: vZY2XY1RD9HIfWi8ift-1_DnHLDadZMWrufSh-_rKF0;
```
## local node

```sh
HB_CONFIG=config.json rebar3 device local
```

`config.json` pins the published `mint-authority@1.0`, `process-outbox@1.0`,
and `security@1.0` implementations through HyperBEAM's `trusted-devices` runtime map.

src:

* https://github.com/permaweb/process-outbox-1.0
* https://github.com/permaweb/security-1.0
* https://github.com/permaweb/mint-authority

```json
{
  "trusted-devices": {
    "mint-authority@1.0": "uzHd158Q7i40TDjwsbGAB88E_idazRRIBctTq_rLzGo",
    "process-outbox@1.0": "HOcPV7wxMHYb3rSQ3EfykQhHx_b8waRWhXolhcBNgHo",
    "security@1.0": "7jivsYHKbkfca8emXGepD-T0KQ6cI7ehGLeU3Mn8g6M"
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
rebar3 device publish --device-src=src,_build/default/lib/hb/src/preloaded/token --key wallet.json
```

## License
this package is licensed under the [MIT License](./LICENSE)
