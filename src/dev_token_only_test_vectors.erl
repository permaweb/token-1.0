%%% @doc Token-only tests for fixed-supply ownership ledgers.
-module(dev_token_only_test_vectors).
-include_lib("eunit/include/eunit.hrl").
-include_lib("hb/include/hb.hrl").

opts() ->
    hb:init(),
    #{
        <<"load-remote-devices">> => false,
        <<"priv-wallet">> => ar_wallet:new(),
        store => [hb_test_utils:test_store()]
    }.

id(Bin) when is_binary(Bin) ->
    BitSize = byte_size(Bin) * 8,
    Suffix = <<0:(256 - BitSize)>>,
    <<Bin/binary, Suffix/binary>>;
id(Other) ->
    hb_util:human_id(Other).

token_state(Params, Opts) ->
    InitialBalances = maps:get(initial_balances, Params, #{}),
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
                <<"mint-device">> => <<"mint-authority@1.0">>,
                <<"mint-authority">> => id(<<"minter">>),
                <<"name">> => <<"Test Token">>,
                <<"ticker">> => <<"TEST">>,
                <<"denomination">> => 0,
                <<"total-supply">> => TotalSupply,
                <<"balances">> => Balances
            },
            Extra
        ),
    lib_process:ensure_process_key(hb_message:commit(Base, Opts), Opts).

balance(State, Account, Opts) ->
    Balances = hb_ao:get(<<"balances">>, State, Opts),
    case hb_ao:resolve(Balances, Account, Opts) of
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

set_field(State, From, Fields, Opts) ->
    dev_token:handle_action(
        <<"set">>,
        State,
        #{ <<"body">> => Fields#{ <<"from">> => From } },
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
