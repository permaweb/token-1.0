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

malformed_actions_do_not_block_process_test_() ->
    {timeout, 120, fun malformed_actions_do_not_block_process/0}.

malformed_actions_do_not_block_process() ->
    Opts = opts(),
    {Sender, SenderWallet} = signer(),
    {Recipient, _RecipientWallet} = signer(),
    {MintAuthority, MintAuthorityWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [],
                <<"mint-device">> => <<"mint-authority@1.0">>,
                <<"mint-authority">> => MintAuthority,
                <<"balances">> => #{ Sender => 10, MintAuthority => 1 },
                <<"total-supply">> => 11
            },
            Opts
        ),
    FailedRequests =
        [
            {#{ <<"action">> => #{} }, SenderWallet},
            {#{ <<"action">> => <<255>> }, SenderWallet},
            {
                #{
                    <<"action">> => <<"Transfer">>,
                    <<"recipient">> => #{},
                    <<"quantity">> => 1
                },
                SenderWallet
            },
            {
                #{
                    <<"action">> => <<"Transfer">>,
                    <<"recipient">> => Recipient,
                    <<"quantity">> => #{}
                },
                SenderWallet
            },
            {#{ <<"action">> => <<"Set">>, <<"transfer-enabled">> => false },
                SenderWallet},
            {#{ <<"action">> => <<"Subscribe">>, <<"subscribe-action">> => #{} },
                SenderWallet},
            {
                #{
                    <<"action">> => <<"Subscribe">>,
                    <<"subscribe-action">> => <<"Credit-Notice">>,
                    <<"subscribe-target">> => #{}
                },
                SenderWallet
            },
            {#{ <<"action">> => <<"Unsubscribe">>, <<"subscribe-action">> => #{} },
                SenderWallet},
            {
                #{
                    <<"action">> => <<"Mint">>,
                    <<"mint-nonce">> => 0,
                    <<"mode">> => <<"single">>,
                    <<"recipient">> => #{},
                    <<"quantity">> => 1
                },
                MintAuthorityWallet
            },
            {
                #{
                    <<"action">> => <<"Mint">>,
                    <<"mint-nonce">> => 0,
                    <<"mode">> => <<"batch">>,
                    <<"quantities">> => #{ Recipient => #{} }
                },
                MintAuthorityWallet
            },
            {#{ <<"action">> => <<"Deposit">> }, MintAuthorityWallet}
        ],
    {FailedState, NextSlot} =
        lists:foldl(
            fun({Request, Wallet}, {Process, Slot}) ->
                {Slot, Computed} =
                    schedule_and_compute(Process, Request, Wallet, Wallet, Opts),
                ?assertEqual(Slot, hb_ao:get(<<"at-slot">>, Computed, Opts)),
                ?assertEqual(10, balance(Computed, Sender, Opts)),
                ?assertEqual(0, balance(Computed, Recipient, Opts)),
                ?assertEqual(1, balance(Computed, MintAuthority, Opts)),
                ?assertEqual(11, state_field(Computed, <<"total-supply">>, 0, Opts)),
                {Computed, Slot + 1}
            end,
            {Process0, 0},
            FailedRequests
        ),
    {NextSlot, FinalState} =
        schedule_and_compute(
            FailedState,
            #{
                <<"action">> => <<"Transfer">>,
                <<"recipient">> => Recipient,
                <<"quantity">> => 1
            },
            SenderWallet,
            SenderWallet,
            Opts
        ),
    ?assertEqual(NextSlot, hb_ao:get(<<"at-slot">>, FinalState, Opts)),
    ?assertEqual(9, balance(FinalState, Sender, Opts)),
    ?assertEqual(1, balance(FinalState, Recipient, Opts)),
    ?assertEqual(1, balance(FinalState, MintAuthority, Opts)),
    ?assertEqual(11, state_field(FinalState, <<"total-supply">>, 0, Opts)).

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
                <<"mint-nonce">> => 0,
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
                <<"mint-nonce">> => 0,
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

mint_enabled_council_control_through_scheduler_test_() ->
    {timeout, 120, fun mint_enabled_council_control_through_scheduler/0}.

mint_enabled_council_control_through_scheduler() ->
    Opts = opts(),
    {AdminA, AdminAWallet} = signer(),
    {AdminB, AdminBWallet} = signer(),
    {AdminC, _AdminCWallet} = signer(),
    {MintAuthority, MintAuthorityWallet} = signer(),
    {Recipient, _RecipientWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [],
                <<"mint-device">> => <<"mint-authority@1.0">>,
                <<"mint-authority">> => MintAuthority,
                <<"mint-enabled">> => false,
                <<"set-authority">> => [AdminA, AdminB, AdminC],
                <<"set-authority-match">> => 2,
                <<"whitelisted-fields">> => [<<"mint-enabled">>],
                <<"balances">> => #{ MintAuthority => 1 },
                <<"total-supply">> => 1
            },
            Opts
        ),
    MintRequest =
        #{
            <<"action">> => <<"Mint">>,
            <<"mint-nonce">> => 0,
            <<"mode">> => <<"single">>,
            <<"recipient">> => Recipient,
            <<"quantity">> => 7
        },
    {0, DisabledMint} =
        schedule_and_compute(
            Process0,
            MintRequest,
            MintAuthorityWallet,
            MintAuthorityWallet,
            Opts
        ),
    ?assertEqual(0, balance(DisabledMint, Recipient, Opts)),
    ?assertEqual(1, state_field(DisabledMint, <<"total-supply">>, 0, Opts)),
    {1, SingleSignerSet} =
        schedule_and_compute(
            DisabledMint,
            #{
                <<"action">> => <<"Set">>,
                <<"mint-enabled">> => true,
                <<"timestamp">> => 1
            },
            AdminAWallet,
            AdminAWallet,
            Opts
        ),
    ?assertEqual(
        false,
        state_field(SingleSignerSet, <<"mint-enabled">>, not_found, Opts)
    ),
    {2, Enabled} =
        schedule_and_compute(
            SingleSignerSet,
            #{
                <<"action">> => <<"Set">>,
                <<"mint-enabled">> => true,
                <<"timestamp">> => 2
            },
            [AdminAWallet, AdminBWallet],
            AdminAWallet,
            Opts
        ),
    ?assertEqual(true, state_field(Enabled, <<"mint-enabled">>, not_found, Opts)),
    {3, Minted} =
        schedule_and_compute(
            Enabled,
            MintRequest,
            MintAuthorityWallet,
            MintAuthorityWallet,
            Opts
        ),
    ?assertEqual(7, balance(Minted, Recipient, Opts)),
    ?assertEqual(8, state_field(Minted, <<"total-supply">>, 0, Opts)),
    {4, DisabledAgain} =
        schedule_and_compute(
            Minted,
            #{
                <<"action">> => <<"Set">>,
                <<"mint-enabled">> => false,
                <<"timestamp">> => 3
            },
            [AdminAWallet, AdminBWallet],
            AdminAWallet,
            Opts
        ),
    {5, RejectedAgain} =
        schedule_and_compute(
            DisabledAgain,
            MintRequest#{ <<"quantity">> => 3 },
            MintAuthorityWallet,
            MintAuthorityWallet,
            Opts
        ),
    ?assertEqual(7, balance(RejectedAgain, Recipient, Opts)),
    ?assertEqual(8, state_field(RejectedAgain, <<"total-supply">>, 0, Opts)).

max_supply_council_control_through_scheduler_test_() ->
    {timeout, 120, fun max_supply_council_control_through_scheduler/0}.

max_supply_council_control_through_scheduler() ->
    Opts = opts(),
    {AdminA, AdminAWallet} = signer(),
    {AdminB, AdminBWallet} = signer(),
    {AdminC, _AdminCWallet} = signer(),
    {MintAuthority, MintAuthorityWallet} = signer(),
    {Recipient, _RecipientWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [],
                <<"mint-device">> => <<"mint-authority@1.0">>,
                <<"mint-authority">> => MintAuthority,
                <<"max-supply">> => 5,
                <<"max-supply-enabled">> => true,
                <<"set-authority">> => [AdminA, AdminB, AdminC],
                <<"set-authority-match">> => 2,
                <<"whitelisted-fields">> => [<<"max-supply-enabled">>],
                <<"balances">> => #{ MintAuthority => 1 },
                <<"total-supply">> => 1
            },
            Opts
        ),
    MintRequest =
        #{
            <<"action">> => <<"Mint">>,
            <<"mint-nonce">> => 0,
            <<"mode">> => <<"single">>,
            <<"recipient">> => Recipient,
            <<"quantity">> => 5
        },
    {0, Capped} =
        schedule_and_compute(
            Process0,
            MintRequest,
            MintAuthorityWallet,
            MintAuthorityWallet,
            Opts
        ),
    ?assertEqual(0, balance(Capped, Recipient, Opts)),
    ?assertEqual(1, state_field(Capped, <<"total-supply">>, 0, Opts)),
    {1, SingleSignerSet} =
        schedule_and_compute(
            Capped,
            #{
                <<"action">> => <<"Set">>,
                <<"max-supply-enabled">> => false,
                <<"timestamp">> => 1
            },
            AdminAWallet,
            AdminAWallet,
            Opts
        ),
    ?assertEqual(
        true,
        state_field(SingleSignerSet, <<"max-supply-enabled">>, not_found, Opts)
    ),
    {2, Disabled} =
        schedule_and_compute(
            SingleSignerSet,
            #{
                <<"action">> => <<"Set">>,
                <<"max-supply-enabled">> => false,
                <<"timestamp">> => 2
            },
            [AdminAWallet, AdminBWallet],
            AdminAWallet,
            Opts
        ),
    ?assertEqual(
        false,
        state_field(Disabled, <<"max-supply-enabled">>, not_found, Opts)
    ),
    {3, Minted} =
        schedule_and_compute(
            Disabled,
            MintRequest,
            MintAuthorityWallet,
            MintAuthorityWallet,
            Opts
        ),
    ?assertEqual(5, balance(Minted, Recipient, Opts)),
    ?assertEqual(6, state_field(Minted, <<"total-supply">>, 0, Opts)).

delegated_action_allowlist_through_scheduler_test_() ->
    {timeout, 120, fun delegated_action_allowlist_through_scheduler/0}.

delegated_action_allowlist_through_scheduler() ->
    Opts = opts(),
    SchedulerWallet = maps:get(<<"priv-wallet">>, Opts),
    Scheduler = hb_util:human_id(ar_wallet:to_address(SchedulerWallet)),
    {Admin, AdminWallet} = signer(),
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
                <<"authority-actions">> =>
                    [<<"Transfer">>, <<"Subscribe">>, <<"Unsubscribe">>],
                <<"set-authority">> => Admin,
                <<"whitelisted-fields">> => [<<"allowed-subscriptions">>],
                <<"allowed-subscriptions">> =>
                    [
                        #{
                            <<"action">> => <<"register">>,
                            <<"target">> => <<"broadcast">>,
                            <<"listener">> => Dex
                        }
                    ],
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
    {1, Subscribed} =
        schedule_and_compute(
            Transferred,
            #{
                <<"action">> => <<"Subscribe">>,
                <<"from-process">> => Dex,
                <<"subscribe-action">> => <<"register">>,
                <<"timestamp">> => 1
            },
            SchedulerWallet,
            SchedulerWallet,
            Opts
        ),
    ?assertEqual([Dex], dev_token_lib:subscribers(Subscribed, <<"register">>, Opts)),
    {2, Unsubscribed} =
        schedule_and_compute(
            Subscribed,
            #{
                <<"action">> => <<"Unsubscribe">>,
                <<"from-process">> => Dex,
                <<"subscribe-action">> => <<"register">>
            },
            SchedulerWallet,
            SchedulerWallet,
            Opts
        ),
    ?assertEqual([], dev_token_lib:subscribers(Unsubscribed, <<"register">>, Opts)),
    {3, SubscriptionsDisabled} =
        schedule_and_compute(
            Unsubscribed,
            #{
                <<"action">> => <<"Set">>,
                <<"allowed-subscriptions">> => []
            },
            AdminWallet,
            AdminWallet,
            Opts
        ),
    {4, RejectedSubscription} =
        schedule_and_compute(
            SubscriptionsDisabled,
            #{
                <<"action">> => <<"Subscribe">>,
                <<"from-process">> => Dex,
                <<"subscribe-action">> => <<"register">>,
                <<"timestamp">> => 2
            },
            SchedulerWallet,
            SchedulerWallet,
            Opts
        ),
    ?assertEqual(
        [],
        dev_token_lib:subscribers(RejectedSubscription, <<"register">>, Opts)
    ),
    {5, RejectedMint} =
        schedule_and_compute(
            RejectedSubscription,
            #{
                <<"action">> => <<"Mint">>,
                <<"mint-nonce">> => 0,
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

mint_nonce_replay_rejected_through_scheduler_test_() ->
    {timeout, 120, fun mint_nonce_replay_rejected_through_scheduler/0}.

mint_nonce_replay_rejected_through_scheduler() ->
    Opts = opts(),
    {MintAuthority, MintAuthorityWallet} = signer(),
    {Recipient, _RecipientWallet} = signer(),
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
    MintBody =
        #{
            <<"action">> => <<"Mint">>,
            <<"mint-nonce">> => 42,
            <<"mode">> => <<"single">>,
            <<"recipient">> => Recipient,
            <<"quantity">> => 3
        },
    SignedMint = sign_body(Process0, MintBody, MintAuthorityWallet, Opts),
    {0, _} = schedule(Process0, SignedMint, MintAuthorityWallet, Opts),
    {ok, Process1} =
        hb_ao:resolve(
            Process0,
            #{ <<"path">> => <<"compute">>, <<"slot">> => 0 },
            Opts
        ),
    ?assertEqual(3, balance(Process1, Recipient, Opts)),
    ?assertEqual(4, state_field(Process1, <<"total-supply">>, 0, Opts)),
    ?assertEqual(42, state_field(Process1, <<"mint-nonce">>, -1, Opts)),

    ResignedMint = sign_body(Process1, MintBody, MintAuthorityWallet, Opts),
    ?assertEqual(
        hb_message:id(SignedMint, none, Opts),
        hb_message:id(ResignedMint, none, Opts)
    ),
    ?assertNotEqual(
        hb_message:id(SignedMint, signed, Opts),
        hb_message:id(ResignedMint, signed, Opts)
    ),
    {1, _} = schedule(Process1, ResignedMint, MintAuthorityWallet, Opts),
    {ok, Process2} =
        hb_ao:resolve(
            Process1,
            #{ <<"path">> => <<"compute">>, <<"slot">> => 1 },
            Opts
        ),
    ?assertEqual(1, hb_ao:get(<<"at-slot">>, Process2, Opts)),
    ?assertEqual(3, balance(Process2, Recipient, Opts)),
    ?assertEqual(4, state_field(Process2, <<"total-supply">>, 0, Opts)),
    ?assertEqual(42, state_field(Process2, <<"mint-nonce">>, -1, Opts)),

    {2, Process3} =
        schedule_and_compute(
            Process2,
            MintBody#{ <<"mint-nonce">> => 43 },
            MintAuthorityWallet,
            MintAuthorityWallet,
            Opts
        ),
    ?assertEqual(6, balance(Process3, Recipient, Opts)),
    ?assertEqual(7, state_field(Process3, <<"total-supply">>, 0, Opts)),
    ?assertEqual(43, state_field(Process3, <<"mint-nonce">>, -1, Opts)).

delegated_signature_expansion_replay_rejected_test_() ->
    {timeout, 120, fun delegated_signature_expansion_replay_rejected/0}.

delegated_signature_expansion_replay_rejected() ->
    Opts = opts(),
    SchedulerWallet = maps:get(<<"priv-wallet">>, Opts),
    Scheduler = hb_util:human_id(ar_wallet:to_address(SchedulerWallet)),
    {Dex, _DexWallet} = signer(),
    {Recipient, _RecipientWallet} = signer(),
    {_External, ExternalWallet} = signer(),
    Process0 =
        dev_token_lib:ledger(
            #{
                <<"execution-device">> => <<"token@1.0">>,
                <<"security-device">> => <<"security@1.0">>,
                <<"authority">> => [Scheduler],
                <<"authority-match">> => 1,
                <<"authority-actions">> => [<<"Transfer">>],
                <<"balances">> => #{Dex => 10},
                <<"total-supply">> => 10
            },
            Opts
        ),
    SignedBody =
        sign_body(
            Process0,
            #{
                <<"action">> => <<"Transfer">>,
                <<"from-process">> => Dex,
                <<"recipient">> => Recipient,
                <<"quantity">> => 3
            },
            SchedulerWallet,
            Opts
        ),
    {0, _} = schedule(Process0, SignedBody, SchedulerWallet, Opts),
    {ok, Process1} =
        hb_ao:resolve(
            Process0,
            #{<<"path">> => <<"compute">>, <<"slot">> => 0},
            Opts
        ),
    ?assertEqual(7, balance(Process1, Dex, Opts)),
    ?assertEqual(3, balance(Process1, Recipient, Opts)),

    ExpandedBody =
        hb_message:commit(
            SignedBody,
            Opts#{<<"priv-wallet">> => ExternalWallet}
        ),
    ?assertEqual(2, length(lists:uniq(hb_message:signers(ExpandedBody, Opts)))),
    {1, _} = schedule(Process1, ExpandedBody, ExternalWallet, Opts),
    {ok, Process2} =
        hb_ao:resolve(
            Process1,
            #{<<"path">> => <<"compute">>, <<"slot">> => 1},
            Opts
        ),
    ?assertEqual(7, balance(Process2, Dex, Opts)),
    ?assertEqual(3, balance(Process2, Recipient, Opts)).
