%%% @doc End-to-end token vectors through process scheduling and computation.
-module(hb_token_process_scheduler_test_vectors).
-include_lib("eunit/include/eunit.hrl").
-include_lib("hb/include/hb.hrl").

opts() ->
    ensure_lib_token(),
    hb:init(),
    #{
        <<"load-remote-devices">> => false,
        <<"priv-wallet">> => ar_wallet:new(),
        dev_security_mode => prod,
        <<"store">> => [hb_test_utils:test_store()]
    }.

ensure_lib_token() ->
    case code:ensure_loaded(lib_token) of
        {module, lib_token} ->
            ok;
        {error, _} ->
            Source = lib_token_source(),
            case compile:file(
                Source,
                [
                    debug_info,
                    binary,
                    {i, "src"},
                    {i, "_build/default/lib/hb/src"},
                    {i, "_build/default/lib/hb/include"}
                ]
            ) of
                {ok, lib_token, Beam} ->
                    case code:load_binary(lib_token, Source, Beam) of
                        {module, lib_token} -> ok;
                        {error, already_loaded} -> ok;
                        Other -> erlang:error({lib_token_load_failed, Other})
                    end;
                Other ->
                    erlang:error({lib_token_compile_failed, Other})
            end
    end.

lib_token_source() ->
    Candidates =
        [
            filename:join(
                [
                    "_build/default/lib/hb",
                    "src",
                    "preloaded",
                    "token",
                    "lib_token.erl"
                ]
            )
        ] ++
            case code:lib_dir(hb) of
                {error, _} -> [];
                HBDir ->
                    [
                        filename:join(
                            [HBDir, "src", "preloaded", "token", "lib_token.erl"]
                        )
                    ]
            end,
    case lists:dropwhile(fun(Path) -> not filelib:is_regular(Path) end, Candidates) of
        [Path | _] -> Path;
        [] ->
            filename:join(
                [
                    "_build/default/lib/hb",
                    "src",
                    "preloaded",
                    "token",
                    "lib_token.erl"
                ]
            )
    end.

signer() ->
    Wallet = ar_wallet:new(),
    {hb_util:human_id(ar_wallet:to_address(Wallet)), Wallet}.

process_id(Process, Opts) ->
    ProcMsg =
        case hb_ao:get(
            <<"process">>,
            Process,
            not_found,
            Opts#{ <<"hashpath">> => ignore }
        ) of
            not_found ->
                {ok, Committed} = hb_message:with_only_committed(Process, Opts),
                Committed;
            Committed ->
                Committed
        end,
    true = hb_message:verify(ProcMsg, all, Opts),
    [_ | _] = hb_message:signers(ProcMsg, Opts),
    hb_message:id(ProcMsg, signed, Opts).

sign_body(Process, Body, RawWallets, Opts) ->
    Wallets = case RawWallets of
        List when is_list(List) -> List;
        Wallet -> [Wallet]
    end,
    Message =
        maps:merge(
            #{
                <<"type">> => <<"Message">>,
                <<"target">> => process_id(Process, Opts)
            },
            Body
        ),
    Signed =
        lists:foldl(
        fun(Wallet, Msg) ->
                hb_message:commit(Msg, Opts#{ <<"priv-wallet">> => Wallet })
            end,
            Message,
            Wallets
        ),
    true = hb_message:verify(Signed, signers, Opts),
    {ok, _} = hb_cache:write(Signed, Opts),
    Signed.

schedule(Process, SignedBody, RequestWallet, Opts) ->
    UserOpts = Opts#{ <<"priv-wallet">> => RequestWallet },
    SignedReq0 =
        hb_message:commit(
            #{
                <<"path">> => <<"schedule">>,
                <<"method">> => <<"POST">>,
                <<"body">> => SignedBody
            },
            UserOpts
        ),
    % Restore nested commitment metadata in the same form loaded from cache by
    % the scheduler. This does not alter the outer request's signed content.
    SignedReq = SignedReq0#{ <<"body">> => SignedBody },
    true = hb_message:verify(SignedReq, signers, Opts),
    {ok, Scheduled} = hb_ao:resolve(Process, SignedReq, Opts),
    {hb_util:int(hb_ao:get(<<"slot">>, Scheduled, Opts)), Scheduled}.

schedule_and_compute(Process, Body, BodyWallets, RequestWallet, Opts) ->
    SignedBody = sign_body(Process, Body, BodyWallets, Opts),
    {Slot, _Scheduled} = schedule(Process, SignedBody, RequestWallet, Opts),
    {ok, Computed} =
        hb_ao:resolve(
            Process,
            #{ <<"path">> => <<"compute">>, <<"slot">> => Slot },
            Opts
        ),
    {Slot, Computed}.

balance(Process, Account, Opts) ->
    dev_token_lib:balance(Process, Account, Opts).

state_field(Process, Key, Default, Opts) ->
    hb_ao:get(<<"now/", Key/binary>>, Process, Default, Opts).

scheduled_paths_are_noops_and_process_continues_test_() ->
    {timeout, 120, fun scheduled_paths_are_noops_and_process_continues/0}.

scheduled_paths_are_noops_and_process_continues() ->
    Opts = opts(),
    {Sender, SenderWallet} = signer(),
    {Recipient, _RecipientWallet} = signer(),
    {UnauthorizedCaller, UnauthorizedWallet} = signer(),
    {MintAuthority, _MintAuthorityWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [],
                <<"mint-device">> => <<"mint-authority@1.0">>,
                <<"mint-authority">> => MintAuthority,
                <<"balances">> => #{ Sender => 10 },
                <<"total-supply">> => 10
            },
            Opts
        ),
    RejectedRequests =
        [
            #{
                <<"path">> => <<"mint">>,
                <<"from">> => MintAuthority,
                <<"mode">> => <<"single">>,
                <<"recipient">> => UnauthorizedCaller,
                <<"quantity">> => 100
            },
            #{ <<"path">> => <<"balances">> },
            #{ <<"path">> => <<"compute/balances">> }
        ],
    {Process3, 3} =
        lists:foldl(
            fun(Request, {Process, ExpectedSlot}) ->
                {ExpectedSlot, Computed} =
                    schedule_and_compute(
                        Process,
                        Request,
                        UnauthorizedWallet,
                        UnauthorizedWallet,
                        Opts
                    ),
                ?assertEqual(ExpectedSlot, hb_ao:get(<<"at-slot">>, Computed, Opts)),
                ?assertEqual(10, balance(Computed, Sender, Opts)),
                ?assertEqual(0, balance(Computed, UnauthorizedCaller, Opts)),
                ?assertEqual(10, state_field(Computed, <<"total-supply">>, 0, Opts)),
                {Computed, ExpectedSlot + 1}
            end,
            {Process0, 0},
            RejectedRequests
        ),
    {3, Process4} =
        schedule_and_compute(
            Process3,
            #{
                <<"action">> => <<"Transfer">>,
                <<"recipient">> => Recipient,
                <<"quantity">> => 1
            },
            SenderWallet,
            SenderWallet,
            Opts
        ),
    ?assertEqual(3, hb_ao:get(<<"at-slot">>, Process4, Opts)),
    ?assertEqual(9, balance(Process4, Sender, Opts)),
    ?assertEqual(1, balance(Process4, Recipient, Opts)),
    ?assertEqual(0, balance(Process4, UnauthorizedCaller, Opts)),
    ?assertEqual(10, state_field(Process4, <<"total-supply">>, 0, Opts)).

two_of_three_set_succeeds_through_scheduler_test_() ->
    {timeout, 120, fun two_of_three_set_succeeds_through_scheduler/0}.

two_of_three_set_succeeds_through_scheduler() ->
    Opts = opts(),
    {AdminA, AdminAWallet} = signer(),
    {AdminB, AdminBWallet} = signer(),
    {AdminC, _AdminCWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [],
                <<"set-authority">> => [AdminA, AdminB, AdminC],
                <<"set-authority-match">> => 2,
                <<"whitelisted-fields">> =>
                    [<<"transfer-enabled">>, <<"authority">>, <<"authority-actions">>],
                <<"authority-actions">> => [<<"Transfer">>],
                <<"transfer-enabled">> => false,
                <<"balances">> => #{ AdminA => 1 },
                <<"total-supply">> => 1
            },
            Opts
        ),
    {0, Updated} =
        schedule_and_compute(
            Process0,
            #{
                <<"action">> => <<"Set">>,
                <<"transfer-enabled">> => true,
                <<"authority">> => [AdminC],
                <<"authority-actions">> => [<<"Transfer">>, <<"Subscribe">>]
            },
            [AdminAWallet, AdminBWallet],
            AdminAWallet,
            Opts
        ),
    ?assertEqual(0, hb_ao:get(<<"at-slot">>, Updated, Opts)),
    ?assertEqual(
        true,
        state_field(Updated, <<"transfer-enabled">>, not_found, Opts)
    ),
    ?assertEqual(
        [<<"Transfer">>, <<"Subscribe">>],
        state_field(Updated, <<"authority-actions">>, not_found, Opts)
    ),
    ?assertEqual(
        [AdminC],
        state_field(Updated, <<"authority">>, not_found, Opts)
    ).

wallet_only_mint_authority_through_scheduler_test_() ->
    {timeout, 120, fun wallet_only_mint_authority_through_scheduler/0}.

wallet_only_mint_authority_through_scheduler() ->
    Opts = opts(),
    {MintAuthority, MintAuthorityWallet} = signer(),
    {Recipient, NonAuthorityWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [],
                <<"mint-device">> => <<"mint-authority@1.0">>,
                <<"mint-authority">> => MintAuthority,
                <<"balances">> => #{ MintAuthority => 1 },
                <<"total-supply">> => 1
            },
            Opts
        ),
    {0, Rejected} =
        schedule_and_compute(
            Process0,
            #{
                <<"action">> => <<"Mint">>,
                <<"from-process">> => MintAuthority,
                <<"mode">> => <<"single">>,
                <<"recipient">> => Recipient,
                <<"quantity">> => 100
            },
            NonAuthorityWallet,
            NonAuthorityWallet,
            Opts
        ),
    ?assertEqual(0, balance(Rejected, Recipient, Opts)),
    ?assertEqual(1, state_field(Rejected, <<"total-supply">>, 0, Opts)),
    {1, Minted} =
        schedule_and_compute(
            Rejected,
            #{
                <<"action">> => <<"Mint">>,
                <<"mode">> => <<"single">>,
                <<"recipient">> => Recipient,
                <<"quantity">> => 7
            },
            MintAuthorityWallet,
            MintAuthorityWallet,
            Opts
        ),
    ?assertEqual(7, balance(Minted, Recipient, Opts)),
    ?assertEqual(8, state_field(Minted, <<"total-supply">>, 0, Opts)).

delegated_action_allowlist_through_scheduler_test_() ->
    {timeout, 120, fun delegated_action_allowlist_through_scheduler/0}.

delegated_action_allowlist_through_scheduler() ->
    Opts = opts(),
    SchedulerWallet = maps:get(<<"priv-wallet">>, Opts),
    Scheduler = hb_util:human_id(ar_wallet:to_address(SchedulerWallet)),
    {Dex, _DexWallet} = signer(),
    {Recipient, _RecipientWallet} = signer(),
    {MintAuthority, _MintAuthorityWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [Scheduler],
                <<"authority-match">> => 1,
                <<"authority-actions">> => [<<"Transfer">>],
                <<"mint-device">> => <<"mint-authority@1.0">>,
                <<"mint-authority">> => MintAuthority,
                <<"balances">> => #{ Dex => 10 },
                <<"total-supply">> => 10
            },
            Opts
        ),
    {0, Transferred} =
        schedule_and_compute(
            Process0,
            #{
                <<"action">> => <<"Transfer">>,
                <<"from-process">> => Dex,
                <<"recipient">> => Recipient,
                <<"quantity">> => 3
            },
            SchedulerWallet,
            SchedulerWallet,
            Opts
        ),
    ?assertEqual(7, balance(Transferred, Dex, Opts)),
    ?assertEqual(3, balance(Transferred, Recipient, Opts)),
    ?assertEqual(10, state_field(Transferred, <<"total-supply">>, 0, Opts)),
    {1, RejectedMint} =
        schedule_and_compute(
            Transferred,
            #{
                <<"action">> => <<"Mint">>,
                <<"from-process">> => MintAuthority,
                <<"mode">> => <<"single">>,
                <<"recipient">> => Recipient,
                <<"quantity">> => 100
            },
            SchedulerWallet,
            SchedulerWallet,
            Opts
        ),
    ?assertEqual(7, balance(RejectedMint, Dex, Opts)),
    ?assertEqual(3, balance(RejectedMint, Recipient, Opts)),
    ?assertEqual(10, state_field(RejectedMint, <<"total-supply">>, 0, Opts)).
