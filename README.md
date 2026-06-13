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
## published package

```bash
device publish: token@1.0 

spec=TZlNNHoG4OnnL3pbLNxp-3u_TxqKW-AHT6b3PbKruok 

impl=M-VDVKYNRIw6-bgZz2EJbQ6ua-sW2CpYCj9hT42-Rgc 

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

## Publish

```sh
rebar3 device publish --key wallet.json
```
