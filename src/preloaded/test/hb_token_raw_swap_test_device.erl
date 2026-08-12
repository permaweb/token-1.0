%%% @doc Test-only swap device that reproduces arweave-swap's balance update
%%% pattern: read the shared ledger as a map, then write whole account keys with
%%% hb_maps:put/4. It deliberately does not know how to update a radix trie.
-module(hb_token_raw_swap_test_device).
-export([info/0, compute/3, set/3]).

info() ->
    #{ default => fun compute/3 }.

set(Base, Req, Opts) ->
    {ok,
        Base#{
            <<"device">> => hb_maps:get(<<"device">>, Req, undefined, Opts)
        }
    }.

compute(Base, _Assignment, Opts) ->
    Existing = hb_maps:get(<<"test-swap-existing">>, Base, Opts),
    Buyer = hb_maps:get(<<"test-swap-buyer">>, Base, Opts),
    Quantity = hb_maps:get(<<"test-swap-quantity">>, Base, Opts),
    Balances = hb_maps:get(<<"balances">>, Base, Opts),
    ExistingBalance = hb_ao:get(Existing, Balances, 0, Opts),
    UpdatedExisting =
        hb_maps:put(Existing, ExistingBalance - Quantity, Balances, Opts),
    UpdatedBalances = hb_maps:put(Buyer, Quantity, UpdatedExisting, Opts),
    {ok,
        Base#{
            <<"balances">> => UpdatedBalances,
            <<"test-swap-saw-balance-commitments">> =>
                hb_maps:get(<<"commitments">>, Balances, not_found, Opts)
                    =/= not_found
        }
    }.
