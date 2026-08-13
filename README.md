# `token@1.0`

## build and verify

```sh
rebar3 compile
rebar3 device verify --device-src=src,_build/default/lib/hb/src/preloaded/token
rebar3 device package --device-src=src,_build/default/lib/hb/src/preloaded/token
```

## test

```sh
HB_PORT=0 rebar3 mint-authority-test
rebar3 eunit-all
```

## genesis

Initialization requires valid addresses with non-negative integer balances and a
non-negative `total-supply` equal to their sum. Invalid genesis state fails closed.
Tokens configured with `swap-device` retain exact, case-sensitive balance keys.

## swap-device compatibility

When `swap-device` is configured, every scheduled assignment is settled by that
device before token execution. The exact wire actions `make-offer`,
`cancel-order`, and `register-interest` are owned by the swap device and do not
fall through to the token's mint-device hook. Non-target L1 transactions are
settled without running token semantics; process-targeted token actions continue
through deduplication, security, outbox, and mint-authority handling.

Routing uses the real L1 transaction target recorded by `tx@1.0`, rather than a
projected `Target` tag. The node must provide or pin the implementation named by
`swap-device` (for Bazar, `arweave-swap@1.0`); it is not bundled in this token
package. Every node computing the process must use compatible token and swap
implementations before clients rely on the resulting state.

Before swap execution, the token removes the balance trie's root commitment so
the swap device's direct account writes cannot retain stale commitment metadata.
If balances change, the result is rebuilt as a fresh committed `trie@1.0`; if
they do not, the prior trie root is reused. This keeps new buyer accounts durable
through process caching and prevents later slots from changing historical balance
snapshots.

## published package

```bash
Published device: token@1.0; 

Specification ID: epys-UUFO_9h5Bu06_IENleTEwzs3yLdjPSPWxQyoBk;

Implementation ID: GI9XLarMcDT7IOL2X1XFFrHmTeIosrf48vLAQkGdptw;

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
    "security@1.0": "RrkCKxGm72vA9tuDAxKSgDzfvdDhwk1dM0g2ZWmtRKI"
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
