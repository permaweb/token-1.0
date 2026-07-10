%%% @doc Token-only tests for fixed-supply ownership ledgers.
-module(hb_token_test_vectors).
-include_lib("eunit/include/eunit.hrl").
-include_lib("hb/include/hb.hrl").

-define(PROCESS_OUTBOX_DEVICE, <<"process-outbox@1.0">>). 

opts() ->
    hb:init(),
    #{
        <<"priv-wallet">> => ar_wallet:new(),
        <<"store">> => [hb_test_utils:test_store()]
    }.

id(Bin) when is_binary(Bin) ->
    BitSize = byte_size(Bin) * 8,
    Suffix = <<0:(256 - BitSize)>>,
    <<Bin/binary, Suffix/binary>>;
id(Other) ->
    hb_util:human_id(Other).

account_key(Account) ->
    hb_util:account_key(Account).

canonical_balances(Balances) ->
    maps:fold(
        fun(Account, Amount, Acc) ->
            Key = account_key(Account),
            Acc#{ Key => maps:get(Key, Acc, 0) + Amount }
        end,
        #{},
        Balances
    ).

token_state(Params, Opts) ->
    InitialBalances =
        canonical_balances(maps:get(initial_balances, Params, #{})),
    TotalSupply =
        maps:get(
            total_supply,
            Params,
            lists:sum(hb_maps:values(InitialBalances, Opts))
        ),
    {ok, Balances} =
        hb_ao:resolve(
            #{ <<"device">> => <<"trie@1.0">> },
            InitialBalances#{ <<"path">> => <<"set">> },
            Opts
        ),
    Extra = maps:get(extra, Params, #{}),
    Base =
        maps:merge(
            #{
                <<"device">> => <<"token@1.0">>,
                <<"name">> => <<"Test Token">>,
                <<"ticker">> => <<"TEST">>,
                <<"denomination">> => 0,
                <<"total-supply">> => TotalSupply,
                <<"balances">> => Balances
            },
            Extra
        ),
    hb_message:commit(Base, Opts).

balance(State, Account, Opts) ->
    Balances = hb_ao:get(<<"balances">>, State, Opts),
    case hb_ao:resolve(Balances, account_key(Account), Opts) of
        {ok, Amount} -> Amount;
        {error, not_found} -> 0
    end.

public_balance(State, Account, Opts) ->
    dev_token:balance(State, #{ <<"balance">> => Account }, Opts).

outbox(State, Opts) ->
    hb_util:message_to_ordered_list(
        hb_ao:get(<<"results/outbox">>, State, [], Opts),
        Opts
    ).

process_outbox(Opts) ->
    {ok, Outbox} = hb_device_load:reference(?PROCESS_OUTBOX_DEVICE, Opts),
    Outbox.

outbox_subscribe(State, Req, Opts) ->
    (process_outbox(Opts)):subscribe(State, Req, Opts).

outbox_unsubscribe(State, Req, Opts) ->
    (process_outbox(Opts)):unsubscribe(State, Req, Opts).

outbox_subscribers(State, Action, Opts) ->
    outbox_subscribers(State, Action, <<"broadcast">>, Opts).
outbox_subscribers(State, Action, Target, Opts) ->
    {ok, Subscribers} =
        (process_outbox(Opts)):subscribers(
            State,
            #{ <<"action">> => Action, <<"target">> => Target },
            Opts
        ),
    Subscribers.

outbox_send(Message, State, Opts) ->
    {ok, Updated} =
        (process_outbox(Opts)):send(
            State,
            #{ <<"messages">> => Message },
            Opts
        ),
    Updated.

subscription_req(Action, default, Listener, Slot) ->
    #{
        <<"slot">> => Slot,
        <<"body">> =>
            #{
                <<"subscribe-action">> => Action,
                <<"from">> => Listener
            }
    };
subscription_req(Action, Target, Listener, Slot) ->
    #{
        <<"slot">> => Slot,
        <<"body">> =>
            #{
                <<"subscribe-action">> => Action,
                <<"subscribe-target">> => Target,
                <<"from">> => Listener
            }
    }.

has_message(Pairs, Msgs, Opts) ->
    lists:any(
        fun(Msg) ->
            lists:all(
                fun({Key, Value}) ->
                    hb_ao:get(Key, Msg, undefined, Opts) =:= Value
                end,
                Pairs
            )
        end,
        Msgs
    ).

transfer(State, From, To, Quantity, Opts) ->
    dev_token:handle_action(
        <<"transfer">>,
        State,
        #{
            <<"body">> =>
                #{
                    <<"from">> => From,
                    <<"recipient">> => To,
                    <<"quantity">> => Quantity
                }
        },
        Opts
    ).

mint(State, From, Recipient, Quantity, Opts) ->
    dev_token:handle_action(
        <<"mint">>,
        State,
        #{
            <<"body">> =>
                #{
                    <<"from">> => From,
                    <<"recipient">> => Recipient,
                    <<"quantity">> => Quantity
                }
        },
        Opts
    ).

set_field(State, From, Fields, Opts) ->
    dev_token:handle_action(
        <<"set">>,
        State,
        #{ <<"body">> => Fields#{ <<"from">> => From } },
        Opts
    ).

signed_set_field(State, From, Fields, Opts) ->
    SignedBody =
        hb_message:commit(
            Fields#{ <<"action">> => <<"Set">>, <<"from">> => From },
            Opts
        ),
    dev_token:handle_action(
        <<"set">>,
        State,
        #{ <<"body">> => SignedBody },
        Opts
    ).

balance_existing_account_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Base =
        token_state(
            #{ initial_balances => #{ Alice => 7 } },
            Opts
        ),
    ?assertEqual({ok, 7}, public_balance(Base, Alice, Opts)).

mixed_case_initial_balance_uses_canonical_account_test() ->
    Opts = opts(),
    Alice = id(<<"Alice">>),
    Base =
        token_state(
            #{ initial_balances => #{ Alice => 7 } },
            Opts
        ),
    Balances = hb_ao:get(<<"balances">>, Base, Opts),
    ?assertEqual({error, not_found}, hb_ao:resolve(Balances, Alice, Opts)),
    ?assertEqual({ok, 7}, hb_ao:resolve(Balances, account_key(Alice), Opts)),
    ?assertEqual({ok, 7}, public_balance(Base, Alice, Opts)),
    ?assertEqual({ok, 7}, public_balance(Base, account_key(Alice), Opts)).

init_canonicalizes_raw_initial_balances_test() ->
    Opts = opts(),
    Alice = id(<<"Alice">>),
    {ok, RawBalances} =
        hb_ao:resolve(
            #{ <<"device">> => <<"trie@1.0">> },
            #{ Alice => 7, <<"path">> => <<"set">> },
            Opts
        ),
    Base =
        hb_message:commit(
            #{
                <<"device">> => <<"token@1.0">>,
                <<"name">> => <<"Test Token">>,
                <<"ticker">> => <<"TEST">>,
                <<"denomination">> => 0,
                <<"total-supply">> => 7,
                <<"balances">> => RawBalances
            },
            Opts
        ),
    {ok, Initialized} = dev_token:init(Base, #{}, Opts),
    Balances = hb_ao:get(<<"balances">>, Initialized, Opts),
    ?assertEqual({error, not_found}, hb_ao:resolve(Balances, Alice, Opts)),
    ?assertEqual({ok, 7}, hb_ao:resolve(Balances, account_key(Alice), Opts)),
    ?assertEqual({ok, 7}, public_balance(Initialized, Alice, Opts)).

balance_missing_account_returns_zero_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Bob = id(<<"bob">>),
    Base =
        token_state(
            #{ initial_balances => #{ Alice => 7 } },
            Opts
        ),
    ?assertEqual({ok, 0}, public_balance(Base, Bob, Opts)).

balance_reserved_account_rejected_test() ->
    Opts = opts(),
    Base = token_state(#{}, Opts),
    ?assertEqual(
        {error, <<"Address is a reserved ao/custom key">>},
        public_balance(Base, <<"path">>, Opts)
    ).

uppercase_reserved_account_rejected_test() ->
    Opts = opts(),
    Base = token_state(#{}, Opts),
    ?assertEqual(
        {error, <<"Address is a reserved ao/custom key">>},
        public_balance(Base, <<"PATH">>, Opts)
    ),
    ?assertEqual(
        {error, <<"Address uses a reserved trie internal key.">>},
        public_balance(Base, <<"DEVICE">>, Opts)
    ).

basic_transfer_updates_balances_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Bob = id(<<"bob">>),
    Base =
        token_state(
            #{
                initial_balances => #{
                    Alice => 100,
                    Bob => 10
                }
            },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, Bob, 30, Opts),
    ?assertEqual(70, balance(Updated, Alice, Opts)),
    ?assertEqual(40, balance(Updated, Bob, Opts)),
    ?assertEqual(110, hb_ao:get(<<"total-supply">>, Updated, Opts)),
    Notices = outbox(Updated, Opts),
    ?assertEqual(2, length(Notices)),
    ?assertEqual(
        [<<"Credit-Notice">>, <<"Debit-Notice">>],
        lists:sort([hb_ao:get(<<"action">>, Notice, Opts) || Notice <- Notices])
    ).

mixed_case_transfer_updates_canonical_balances_test() ->
    Opts = opts(),
    Alice = id(<<"Alice">>),
    Bob = id(<<"Bob">>),
    Base =
        token_state(
            #{
                initial_balances => #{
                    Alice => 10,
                    Bob => 1
                }
            },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, Bob, 3, Opts),
    ?assertEqual(7, balance(Updated, Alice, Opts)),
    ?assertEqual(4, balance(Updated, Bob, Opts)),
    ?assertEqual(7, balance(Updated, account_key(Alice), Opts)),
    ?assertEqual(4, balance(Updated, account_key(Bob), Opts)),
    Notices = outbox(Updated, Opts),
    [Debit] = [
        Notice
    ||
        Notice <- Notices,
        hb_ao:get(<<"action">>, Notice, Opts) =:= <<"Debit-Notice">>
    ],
    [Credit] = [
        Notice
    ||
        Notice <- Notices,
        hb_ao:get(<<"action">>, Notice, Opts) =:= <<"Credit-Notice">>
    ],
    ?assertEqual(Alice, hb_ao:get(<<"target">>, Debit, Opts)),
    ?assertEqual(Bob, hb_ao:get(<<"target">>, Credit, Opts)),
    ?assertEqual(Alice, hb_ao:get(<<"sender">>, Credit, Opts)).

outbox_default_broadcast_subscription_test() ->
    Opts = opts(),
    {ok, Subscribed} =
        outbox_subscribe(
            #{},
            subscription_req(<<"Ping">>, default, <<"listener-a">>, 11),
            Opts
        ),
    ?assertEqual(
        [<<"listener-a">>],
        outbox_subscribers(Subscribed, <<"Ping">>, Opts)
    ),
    Updated =
        outbox_send(
            #{ <<"action">> => <<"Ping">> },
            Subscribed,
            Opts
        ),
    Notices = outbox(Updated, Opts),
    ?assertEqual(2, length(Notices)),
    ?assert(has_message(
        [
            {<<"action">>, <<"notify">>},
            {<<"target">>, <<"listener-a">>},
            {<<"x-action">>, <<"Ping">>}
        ],
        Notices,
        Opts
    )).

outbox_targeted_subscriptions_do_not_overwrite_test() ->
    Opts = opts(),
    {ok, AliceSubscribed} =
        outbox_subscribe(
            #{},
            subscription_req(<<"Debit-Notice">>, <<"alice">>, <<"listener-a">>, 21),
            Opts
        ),
    {ok, BothSubscribed} =
        outbox_subscribe(
            AliceSubscribed,
            subscription_req(<<"Debit-Notice">>, <<"bob">>, <<"listener-b">>, 22),
            Opts
        ),
    ?assertEqual(
        [<<"listener-a">>],
        outbox_subscribers(
            BothSubscribed,
            <<"Debit-Notice">>,
            <<"alice">>,
            Opts
        )
    ),
    ?assertEqual(
        [<<"listener-b">>],
        outbox_subscribers(
            BothSubscribed,
            <<"Debit-Notice">>,
            <<"bob">>,
            Opts
        )
    ),
    Updated =
        outbox_send(
            #{
                <<"action">> => <<"Debit-Notice">>,
                <<"target">> => <<"alice">>,
                <<"quantity">> => 5
            },
            BothSubscribed,
            Opts
        ),
    Notices = outbox(Updated, Opts),
    ?assert(has_message(
        [
            {<<"action">>, <<"notify">>},
            {<<"target">>, <<"listener-a">>},
            {<<"x-target">>, <<"alice">>},
            {<<"x-quantity">>, 5}
        ],
        Notices,
        Opts
    )),
    ?assertNot(has_message(
        [
            {<<"action">>, <<"notify">>},
            {<<"target">>, <<"listener-b">>}
        ],
        Notices,
        Opts
    )).

outbox_unsubscribe_removes_listener_test() ->
    Opts = opts(),
    Req = subscription_req(<<"Debit-Notice">>, <<"alice">>, <<"listener-a">>, 31),
    {ok, Subscribed} = outbox_subscribe(#{}, Req, Opts),
    {ok, Unsubscribed} = outbox_unsubscribe(Subscribed, Req, Opts),
    ?assertEqual(
        [],
        outbox_subscribers(
            Unsubscribed,
            <<"Debit-Notice">>,
            <<"alice">>,
            Opts
        )
    ),
    Updated =
        outbox_send(
            #{
                <<"action">> => <<"Debit-Notice">>,
                <<"target">> => <<"alice">>
            },
            Unsubscribed,
            Opts
        ),
    ?assertEqual(1, length(outbox(Updated, Opts))).

fixed_supply_transfer_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Bob = id(<<"bob">>),
    Base =
        token_state(
            #{
                total_supply => 1,
                initial_balances => #{ Alice => 1 }
            },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, Bob, 1, Opts),
    ?assertEqual(0, balance(Updated, Alice, Opts)),
    ?assertEqual(1, balance(Updated, Bob, Opts)),
    ?assertEqual(1, hb_ao:get(<<"total-supply">>, Updated, Opts)).

fixed_supply_without_mint_device_cannot_mint_test() ->
    Opts = opts(),
    Owner = id(<<"owner">>),
    Minter = id(<<"minter">>),
    Base =
        token_state(
            #{
                total_supply => 1,
                initial_balances => #{ Owner => 1 }
            },
            Opts
        ),
    ?assertEqual(not_found, hb_ao:get(<<"mint-device">>, Base, Opts)),
    {ok, MintRejected} = mint(Base, Minter, Minter, 1, Opts),
    [Notice] = outbox(MintRejected, Opts),
    ?assertEqual(<<"mint-device not configured">>, hb_ao:get(<<"reason">>, Notice, Opts)),
    ?assertEqual(Minter, hb_ao:get(<<"target">>, Notice, Opts)),
    ?assertEqual(1, balance(MintRejected, Owner, Opts)),
    ?assertEqual(0, balance(MintRejected, Minter, Opts)),
    ?assertEqual(1, hb_ao:get(<<"total-supply">>, MintRejected, Opts)).

mint_authority_mint_test() ->
    Opts = opts(),
    Authority = id(<<"authority">>),
    Recipient = id(<<"recipient">>),
    Base =
        token_state(
            #{
                total_supply => 1,
                initial_balances => #{ Authority => 1 },
                extra =>
                    #{
                        <<"mint-device">> => <<"mint-authority@1.0">>,
                        <<"mint-authority">> => Authority
                    }
            },
            Opts
        ),
    {ok, Minted} = mint(Base, Authority, Recipient, 7, Opts),
    [Notice] = outbox(Minted, Opts),
    ?assertEqual(1, balance(Minted, Authority, Opts)),
    ?assertEqual(7, balance(Minted, Recipient, Opts)),
    ?assertEqual(8, hb_ao:get(<<"total-supply">>, Minted, Opts)),
    ?assertEqual(<<"Mint-Notice">>, hb_ao:get(<<"action">>, Notice, Opts)),
    ?assertEqual(Recipient, hb_ao:get(<<"target">>, Notice, Opts)),
    ?assertEqual(Recipient, hb_ao:get(<<"recipient">>, Notice, Opts)),
    ?assertEqual(7, hb_ao:get(<<"quantity">>, Notice, Opts)).

fixed_supply_name_token_flow_test() ->
    Opts = opts(),
    Owner = id(<<"owner">>),
    NewOwner = id(<<"new-owner">>),
    Admin = <<"pnp-admin">>,
    Base =
        token_state(
            #{
                total_supply => 1,
                initial_balances => #{ Owner => 1 },
                extra =>
                    #{
                        <<"set-authority">> => Admin,
                        <<"whitelisted-fields">> =>
                            [
                                <<"name">>,
                                <<"logo">>,
                                <<"asset-type">>
                            ]
                    }
            },
            Opts
        ),
    ?assertEqual(not_found, hb_ao:get(<<"mint-device">>, Base, Opts)),
    ?assertEqual(
        {error, <<"Too few acceptable committers present.">>},
        set_field(Base, Owner, #{ <<"name">> => <<"alice">> }, Opts)
    ),
    {ok, WithMetadata} =
        set_field(
            Base,
            Admin,
            #{
                <<"name">> => <<"pnp-name">>,
                <<"logo">> => <<"logo-tx-id">>,
                <<"asset-type">> => <<"pnp">>
            },
            Opts
        ),
    ?assertEqual(<<"pnp-name">>, hb_ao:get(<<"name">>, WithMetadata, Opts)),
    ?assertEqual(<<"logo-tx-id">>, hb_ao:get(<<"logo">>, WithMetadata, Opts)),
    ?assertEqual(<<"pnp">>, hb_ao:get(<<"asset-type">>, WithMetadata, Opts)),
    ?assertEqual(
        {error, <<"Attempted to set non-whitelisted fields.">>},
        set_field(WithMetadata, Admin, #{ <<"total-supply">> => 2 }, Opts)
    ),
    {ok, Transferred} = transfer(WithMetadata, Owner, NewOwner, 1, Opts),
    ?assertEqual(0, balance(Transferred, Owner, Opts)),
    ?assertEqual(1, balance(Transferred, NewOwner, Opts)),
    ?assertEqual(1, hb_ao:get(<<"total-supply">>, Transferred, Opts)),
    {ok, MintRejected} = mint(Transferred, Owner, Owner, 1, Opts),
    [Notice | _] = outbox(MintRejected, Opts),
    ?assertEqual(<<"mint-device not configured">>, hb_ao:get(<<"reason">>, Notice, Opts)),
    ?assertEqual(Owner, hb_ao:get(<<"target">>, Notice, Opts)),
    ?assertEqual(0, balance(MintRejected, Owner, Opts)),
    ?assertEqual(1, balance(MintRejected, NewOwner, Opts)),
    ?assertEqual(1, hb_ao:get(<<"total-supply">>, MintRejected, Opts)).

insufficient_balance_transfer_rejected_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Bob = id(<<"bob">>),
    Base =
        token_state(
            #{ initial_balances => #{ Alice => 5 } },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, Bob, 6, Opts),
    ?assertEqual(5, balance(Updated, Alice, Opts)),
    ?assertEqual(0, balance(Updated, Bob, Opts)),
    [Notice] = outbox(Updated, Opts),
    ?assertEqual(Alice, hb_ao:get(<<"target">>, Notice, Opts)),
    ?assertEqual(
        <<"Insufficient balance.">>,
        hb_ao:get(<<"reason">>, Notice, Opts)
    ).

negative_quantity_transfer_rejected_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Bob = id(<<"bob">>),
    Base =
        token_state(
            #{ initial_balances => #{ Alice => 5 } },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, Bob, -1, Opts),
    ?assertEqual(5, balance(Updated, Alice, Opts)),
    ?assertEqual(0, balance(Updated, Bob, Opts)),
    [Notice] = outbox(Updated, Opts),
    ?assertEqual(Alice, hb_ao:get(<<"target">>, Notice, Opts)),
    ?assertEqual(
        <<"Quantity must be a non-negative integer.">>,
        hb_ao:get(<<"reason">>, Notice, Opts)
    ).

self_transfer_keeps_balance_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Base =
        token_state(
            #{ initial_balances => #{ Alice => 5 } },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, Alice, 3, Opts),
    ?assertEqual(5, balance(Updated, Alice, Opts)),
    ?assertEqual(5, hb_ao:get(<<"total-supply">>, Updated, Opts)).

reserved_recipient_transfer_rejected_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Base =
        token_state(
            #{
                total_supply => 1,
                initial_balances => #{ Alice => 1 }
            },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, <<"device">>, 1, Opts),
    ?assertEqual(1, balance(Updated, Alice, Opts)),
    ?assertEqual(0, balance(Updated, <<"device">>, Opts)),
    ?assertEqual(1, hb_ao:get(<<"total-supply">>, Updated, Opts)).

reserved_ao_recipient_transfer_rejected_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Base =
        token_state(
            #{
                total_supply => 1,
                initial_balances => #{ Alice => 1 }
            },
            Opts
        ),
    {ok, Updated} = transfer(Base, Alice, <<"path">>, 1, Opts),
    ?assertEqual(1, balance(Updated, Alice, Opts)),
    ?assertEqual(0, balance(Updated, <<"path">>, Opts)),
    ?assertEqual(1, hb_ao:get(<<"total-supply">>, Updated, Opts)).

non_whitelisted_set_field_rejected_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base =
        token_state(
            #{
                extra =>
                    #{
                        <<"set-authority">> => Setter,
                        <<"whitelisted-fields">> =>
                            [
                                <<"set-authority">>,
                                <<"set-authority-required">>,
                                <<"set-authority-match">>,
                                <<"name">>,
                                <<"ticker">>,
                                <<"denomination">>,
                                <<"logo">>
                            ]
                    }
            },
            Opts
        ),
    ?assertEqual(
        {error, <<"Attempted to set non-whitelisted fields.">>},
        set_field(Base, Setter, #{ <<"balances">> => #{ <<"fake">> => 1 } }, Opts)
    ).

default_whitelist_wildcard_allows_set_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base =
        token_state(
            #{
                extra => #{ <<"set-authority">> => Setter }
            },
            Opts
        ),
    {ok, Updated} =
        set_field(Base, Setter, #{ <<"logo">> => <<"logo-a">> }, Opts),
    ?assertEqual(<<"logo-a">>, hb_ao:get(<<"logo">>, Updated, Opts)).

signed_set_strips_commitments_before_whitelist_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base =
        token_state(
            #{
                extra =>
                    #{
                        <<"set-authority">> => Setter,
                        <<"whitelisted-fields">> => [<<"logo">>]
                    }
            },
            Opts
        ),
    {ok, Updated} =
        signed_set_field(Base, Setter, #{ <<"logo">> => <<"logo-signed">> }, Opts),
    ?assertEqual(<<"logo-signed">>, hb_ao:get(<<"logo">>, Updated, Opts)).

set_does_not_persist_control_keys_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base =
        token_state(
            #{
                extra => #{ <<"set-authority">> => Setter }
            },
            Opts
        ),
    BaseCommitments = hb_maps:get(<<"commitments">>, Base, not_found, Opts),
    ControlFields =
        #{
            <<"action">> => <<"Transfer">>,
            <<"path">> => <<"evil-path">>,
            <<"body">> => #{ <<"evil">> => true },
            <<"commitments">> => #{ <<"evil">> => true },
            <<"committers">> => [<<"evil">>],
            <<"ao-types">> => <<"evil=atom">>,
            <<"target">> => <<"evil-target">>,
            <<"type">> => <<"Message">>,
            <<"id">> => <<"evil-id">>,
            <<"timestamp">> => 1,
            <<"variant">> => <<"evil-variant">>,
            <<"data-protocol">> => <<"evil-protocol">>,
            <<"set-mode">> => <<"explicit">>,
            <<"priv">> => #{ <<"evil">> => true },
            <<"hashpath">> => <<"evil-hashpath">>
        },
    {ok, Updated} =
        set_field(
            Base,
            Setter,
            ControlFields#{ <<"logo">> => <<"logo-a">> },
            Opts
        ),
    ?assertEqual(<<"logo-a">>, hb_ao:get(<<"logo">>, Updated, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"action">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"path">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"body">>, Updated, not_found, Opts)),
    ?assertEqual(
        BaseCommitments,
        hb_maps:get(<<"commitments">>, Updated, not_found, Opts)
    ),
    ?assertEqual(not_found, hb_maps:get(<<"committers">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"ao-types">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"target">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"type">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"id">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"timestamp">>, Updated, not_found, Opts)),
    ?assertEqual(not_found, hb_maps:get(<<"variant">>, Updated, not_found, Opts)),
    ?assertEqual(
        not_found,
        hb_maps:get(<<"data-protocol">>, Updated, not_found, Opts)
    ),
    ?assertEqual(not_found, hb_maps:get(<<"set-mode">>, Updated, not_found, Opts)),
    ?assertNotEqual(
        #{ <<"evil">> => true },
        hb_maps:get(<<"priv">>, Updated, not_found, Opts)
    ),
    ?assertEqual(not_found, hb_maps:get(<<"hashpath">>, Updated, not_found, Opts)).

set_authority_dynamic_full_owner_default_test() ->
    Opts = opts(),
    Owner = id(<<"owner">>),
    Base =
        token_state(
            #{
                total_supply => 10,
                initial_balances => #{ Owner => 10 }
            },
            Opts
        ),
    {ok, Updated} =
        set_field(Base, Owner, #{ <<"logo">> => <<"logo-a">> }, Opts),
    ?assertEqual(<<"logo-a">>, hb_ao:get(<<"logo">>, Updated, Opts)).

set_authority_dynamic_tracks_current_full_owner_test() ->
    Opts = opts(),
    Owner = id(<<"owner">>),
    NewOwner = id(<<"new-owner">>),
    Base =
        token_state(
            #{
                total_supply => 1,
                initial_balances => #{ Owner => 1 }
            },
            Opts
        ),
    {ok, WithLogoA} =
        set_field(Base, Owner, #{ <<"logo">> => <<"logo-a">> }, Opts),
    {ok, Transferred} = transfer(WithLogoA, Owner, NewOwner, 1, Opts),
    ?assertEqual(
        {error, <<"Supply-threshold owner requirement not satisfied.">>},
        set_field(Transferred, Owner, #{ <<"logo">> => <<"logo-b">> }, Opts)
    ),
    {ok, WithLogoC} =
        set_field(Transferred, NewOwner, #{ <<"logo">> => <<"logo-c">> }, Opts),
    ?assertEqual(<<"logo-c">>, hb_ao:get(<<"logo">>, WithLogoC, Opts)).

set_authority_dynamic_split_supply_rejected_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Bob = id(<<"bob">>),
    Base =
        token_state(
            #{
                total_supply => 10,
                initial_balances => #{ Alice => 5, Bob => 5 }
            },
            Opts
        ),
    ?assertEqual(
        {error, <<"Supply-threshold owner requirement not satisfied.">>},
        set_field(Base, Alice, #{ <<"logo">> => <<"logo-a">> }, Opts)
    ).

set_authority_dynamic_threshold_bps_allows_configured_owner_test() ->
    Opts = opts(),
    Alice = id(<<"alice">>),
    Bob = id(<<"bob">>),
    Base =
        token_state(
            #{
                total_supply => 10,
                initial_balances => #{ Alice => 5, Bob => 5 },
                extra =>
                    #{
                        <<"set-authority-template">> => <<"supply-threshold-owner">>,
                        <<"set-authority-threshold-bps">> => 5000
                    }
            },
            Opts
        ),
    {ok, Updated} =
        set_field(Base, Alice, #{ <<"logo">> => <<"logo-a">> }, Opts),
    ?assertEqual(<<"logo-a">>, hb_ao:get(<<"logo">>, Updated, Opts)).

set_authority_dynamic_zero_supply_rejected_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base = token_state(#{}, Opts),
    ?assertEqual(
        {error, <<"Total supply must be positive.">>},
        set_field(Base, Setter, #{ <<"logo">> => <<"logo-a">> }, Opts)
    ).

set_authority_static_uses_dev_security_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base =
        token_state(
            #{
                extra => #{ <<"set-authority">> => Setter }
            },
            Opts
        ),
    {ok, Updated} =
        set_field(Base, Setter, #{ <<"logo">> => <<"logo-a">> }, Opts),
    ?assertEqual(<<"logo-a">>, hb_ao:get(<<"logo">>, Updated, Opts)),
    ?assertEqual(
        {error, <<"Too few acceptable committers present.">>},
        set_field(Base, id(<<"other">>), #{ <<"logo">> => <<"logo-b">> }, Opts)
    ).

set_authority_required_uses_dev_security_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base =
        token_state(
            #{
                extra =>
                    #{
                        <<"set-authority">> => [Setter],
                        <<"set-authority-required">> => [Setter]
                    }
            },
            Opts
        ),
    {ok, Updated} =
        set_field(Base, Setter, #{ <<"logo">> => <<"logo-a">> }, Opts),
    ?assertEqual(<<"logo-a">>, hb_ao:get(<<"logo">>, Updated, Opts)).

set_authority_match_uses_dev_security_test() ->
    Opts = opts(),
    Setter = id(<<"setter">>),
    Base =
        token_state(
            #{
                extra =>
                    #{
                        <<"set-authority">> => [Setter],
                        <<"set-authority-match">> => 1
                    }
            },
            Opts
        ),
    {ok, Updated} =
        set_field(Base, Setter, #{ <<"logo">> => <<"logo-a">> }, Opts),
    ?assertEqual(<<"logo-a">>, hb_ao:get(<<"logo">>, Updated, Opts)).
