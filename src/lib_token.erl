%%% @doc Shared helpers for token-family devices.
-module(lib_token).
-export([validate_address/2]).

-define(AO_RESERVED_ADDRESS_KEYS,
    [
        <<"path">>,
        <<"get">>,
        <<"set">>,
        <<"remove">>,
        <<"verify">>,
        <<"keys">>,
        <<"id">>,
        <<"commit">>,
        <<"committed">>,
        <<"committers">>,
        <<"index">>,
        <<"info">>,
        <<"set_path">>,
        <<"reserved_keys">>,
        <<"is_reserved_key">>,
        <<"dedup">>,
        <<"dedup-subject">>
    ]
).

%% @doc Validate token account/resource address format.
validate_address(Address, CustomList) when is_binary(Address), is_list(CustomList) ->
    ReservedKeys = ?AO_RESERVED_ADDRESS_KEYS ++ CustomList,
    AccountKey = account_key(Address),
    CanonicalReservedKeys = [account_key(Key) || Key <- ReservedKeys, is_binary(Key)],
    case byte_size(Address) of
        0 -> {error, <<"Address cannot be empty.">>};
        N when N > 128 -> {error, <<"Address is too long.">>};
        _ ->
            TrieReservedKeys = trie_reserved_keys(),
            maybe
                true ?= (not is_reserved_trie_key(Address, TrieReservedKeys))
                    orelse {error, <<"Address uses a reserved trie internal key.">>},
                true ?= (not is_reserved_trie_key(AccountKey, TrieReservedKeys))
                    orelse {error, <<"Address uses a reserved trie internal key.">>},
                true ?= (not is_reserved_custom_key(Address, ReservedKeys))
                    orelse {error, <<"Address is a reserved ao/custom key">>},
                true ?= (not is_reserved_custom_key(AccountKey, CanonicalReservedKeys))
                    orelse {error, <<"Address is a reserved ao/custom key">>},
                case binary:match(
                    Address,
                    [<<"/">>, <<"\\">>, <<" ">>, <<"\n">>, <<"\r">>, <<"\t">>]
                ) of
                    nomatch -> true;
                    _ ->
                        {error, <<"Address cannot contain path separators or whitespaces">>}
                end
            end
    end;
validate_address(_, _) ->
    {error, <<"Address must be a binary.">>}.

account_key(Address) when is_binary(Address) ->
    hb_util:to_lower(Address).

is_reserved_trie_key(Key, ReservedKeys) ->
    lists:member(Key, ReservedKeys).

trie_reserved_keys() ->
    {ok, Trie} = hb_device_load:reference(<<"trie@1.0">>, #{}),
    maps:get(reserved, Trie:info(), []).

is_reserved_custom_key(Key, List) when is_binary(Key), is_list(List) ->
    lists:member(Key, List);
is_reserved_custom_key(_, _) ->
    false.
