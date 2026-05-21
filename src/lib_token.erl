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
    case byte_size(Address) of
        0 -> {error, <<"Address cannot be empty.">>};
        N when N > 128 -> {error, <<"Address is too long.">>};
        _ ->
            maybe
                true ?= (not lib_trie:is_reserved_key(Address))
                    orelse {error, <<"Address uses a reserved trie internal key.">>},
                true ?= (not is_reserved_custom_key(Address, ReservedKeys))
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

is_reserved_custom_key(Key, List) when is_binary(Key), is_list(List) ->
    lists:member(Key, List);
is_reserved_custom_key(_, _) ->
    false.
