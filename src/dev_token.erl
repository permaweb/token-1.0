%%% @doc A fast, simple implementation of AO token specification.
%%% Specification: https://cookbook_ao.arweave.net/references/api/token.html
-module(dev_token).
-export([compute/3, init/3, normalize/3, snapshot/3, balance/3, mint/3]).
%%% Non-public device API functions. Note: Ensure that these are not exported
%%% as publicly callable device keys, either by having arity >= 3, or explicitly
%%% excluding in an `info/1` response.
-export([handle_action/4]).
%%% Public helpers.
-export([validate_address/2]).
-include_lib("hb/include/hb.hrl").

-implements(<<"token@1.0">>).
-device_libraries([lib_process, lib_process_outbox, lib_trie]).

%% @doc `Action' values that should be handled by the `mint-device'.
-define(MINT_ACTIONS,
    [
        <<"mint">>,
        <<"deposit">>,
        <<"withdraw">>,
        <<"delegate">>,
        <<"undelegate">>,
        <<"notify">>,
        <<"register">>
    ]
).
%% @doc `validate_address/2` built-in reserved keys list
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

%% @doc Return the configured `set` field whitelist. Defaults to open policy
%% via wildcard unless `whitelisted-fields` is explicitly restricted.
whitelisted_auth_fields(Base, Opts) ->
    maybe
        WhitelistedFields = hb_ao:get(
            <<"whitelisted-fields">>,
            Base,
            [<<"*">>],
            Opts
        ),
        ValidList = case WhitelistedFields of
            V when is_list(V) -> V;
            _ -> {error, <<"Invalid `whitelisted-fields` type.">>}
        end,
        true ?= is_list(ValidList),
        
        lists:filter(
            fun(X) -> is_binary(X) andalso byte_size(X) > 0 end,
            ValidList
        )
end.

%%% `~process@1.0' interface implementation.

%% @doc Canonicalize account keys in the initial balance trie.
init(Base, _Req, Opts) ->
    canonicalize_balances(Base, Opts).

%% @doc Restore token checkpoints when `~process@1.0' loads a cached snapshot.
normalize(Base, _Req, Opts) ->
    case hb_maps:get(<<"snapshot">>, Base, not_found, Opts) of
        not_found ->
            {ok, Base};
        Snapshot0 ->
            Snapshot = hb_cache:ensure_all_loaded(Snapshot0, Opts),
            case is_token_checkpoint(Snapshot) of
                true -> restore_checkpoint(Base, Snapshot, Opts);
                false -> {ok, Base}
            end
    end.

%% @doc Create a self-contained token checkpoint. The token state is serialized
%% into the data body so balance trie keys never become transport tag names.
snapshot(Base, _Req, Opts) ->
    ProcID = lib_process:process_id(Base, #{}, Opts),
    State0 = hb_maps:without([<<"snapshot">>, <<"process">>], Base, Opts),
    State1 = hb_private:reset(State0),
    State = hb_private:reset(hb_cache:ensure_all_loaded(State1, Opts)),
    Payload = term_to_binary(State),
    Snapshot = #{
        <<"type">> => <<"Checkpoint">>,
        <<"checkpoint-device">> => <<"token@1.0">>,
        <<"checkpoint-format">> => <<"erlang-term-v1">>,
        <<"content-type">> => <<"application/octet-stream">>,
        <<"content-encoding">> => <<"gzip">>,
        <<"process-id">> => ProcID,
        <<"state-size">> => byte_size(Payload),
        <<"sha-256">> => hb_util:human_id(crypto:hash(sha256, Payload)),
        <<"timestamp">> => os:system_time(millisecond),
        <<"data">> => zlib:gzip(Payload)
    },
    {ok,
        case hb_ao:get(<<"at-slot">>, Base, undefined, Opts) of
            undefined -> Snapshot;
            Slot -> Snapshot#{ <<"checkpoint-slot">> => Slot }
        end
    }.

is_token_checkpoint(Snapshot) when is_map(Snapshot) ->
    maps:get(<<"checkpoint-device">>, Snapshot, not_found) =:= <<"token@1.0">>;
is_token_checkpoint(_Snapshot) ->
    false.

restore_checkpoint(Base, Snapshot, Opts) ->
    case validate_checkpoint_metadata(Base, Snapshot, Opts) of
        {ok, Process} ->
            case decode_checkpoint_state(Snapshot) of
                {ok, State} ->
                    case validate_checkpoint_state(State) of
                        ok ->
                            Restored0 =
                                hb_maps:without(
                                    [<<"snapshot">>, <<"process">>],
                                    State,
                                    Opts
                                ),
                            {ok,
                                hb_maps:put(
                                    <<"process">>,
                                    Process,
                                    Restored0,
                                    Opts
                                )
                            };
                        Error ->
                            Error
                    end;
                Error ->
                    Error
            end;
        Error ->
            Error
    end.

validate_checkpoint_metadata(Base, Snapshot, Opts) ->
    RequiredFields = [
        {<<"type">>, <<"Checkpoint">>},
        {<<"checkpoint-device">>, <<"token@1.0">>},
        {<<"checkpoint-format">>, <<"erlang-term-v1">>},
        {<<"content-type">>, <<"application/octet-stream">>},
        {<<"content-encoding">>, <<"gzip">>}
    ],
    case validate_checkpoint_fields(Snapshot, RequiredFields) of
        ok ->
            BaseWithProcess = lib_process:ensure_process_key(Base, Opts),
            ProcID = lib_process:process_id(BaseWithProcess, #{}, Opts),
            case maps:get(<<"process-id">>, Snapshot, not_found) of
                ProcID ->
                    case hb_maps:get(
                        <<"process">>,
                        BaseWithProcess,
                        not_found,
                        Opts
                    ) of
                        not_found -> checkpoint_error(missing_process);
                        Process -> {ok, Process}
                    end;
                _ ->
                    checkpoint_error(process_id_mismatch)
            end;
        Error ->
            Error
    end.

validate_checkpoint_fields(_Snapshot, []) ->
    ok;
validate_checkpoint_fields(Snapshot, [{Key, Expected}|Rest]) ->
    case maps:get(Key, Snapshot, not_found) of
        Expected -> validate_checkpoint_fields(Snapshot, Rest);
        _ -> checkpoint_error({invalid_field, Key})
    end.

decode_checkpoint_state(Snapshot) ->
    case {
        maps:get(<<"data">>, Snapshot, not_found),
        maps:get(<<"state-size">>, Snapshot, not_found),
        maps:get(<<"sha-256">>, Snapshot, not_found)
    } of
        {Data, StateSize, Hash}
                when is_binary(Data), is_integer(StateSize),
                     StateSize >= 0, is_binary(Hash) ->
            case gunzip_checkpoint(Data) of
                {ok, Payload} ->
                    ExpectedHash =
                        hb_util:human_id(crypto:hash(sha256, Payload)),
                    case {
                        byte_size(Payload) =:= StateSize,
                        ExpectedHash =:= Hash
                    } of
                        {true, true} -> decode_checkpoint_payload(Payload);
                        {false, _} -> checkpoint_error(state_size_mismatch);
                        {_, false} -> checkpoint_error(hash_mismatch)
                    end;
                Error ->
                    Error
            end;
        _ ->
            checkpoint_error(invalid_payload_metadata)
    end.

gunzip_checkpoint(Data) ->
    try zlib:gunzip(Data) of
        Payload -> {ok, Payload}
    catch
        _:_ -> checkpoint_error(invalid_gzip)
    end.

decode_checkpoint_payload(Payload) ->
    try binary_to_term(Payload, [safe]) of
        State -> {ok, State}
    catch
        _:_ -> checkpoint_error(invalid_erlang_term)
    end.

validate_checkpoint_state(State) when is_map(State) ->
    case {
        maps:get(<<"device">>, State, not_found),
        maps:get(<<"balances">>, State, not_found)
    } of
        {<<"token@1.0">>, Balances} when is_map(Balances) -> ok;
        {<<"token@1.0">>, _} -> checkpoint_error(invalid_balances);
        _ -> checkpoint_error(invalid_token_state)
    end;
validate_checkpoint_state(_State) ->
    checkpoint_error(invalid_token_state).

checkpoint_error(Reason) ->
    {error, {invalid_token_checkpoint, Reason}}.

canonicalize_balances(Base, Opts) ->
    case hb_maps:get(<<"balances">>, Base, not_found, Opts) of
        not_found ->
            {ok, Base};
        Balances0 ->
            Balances = hb_cache:ensure_all_loaded(Balances0, Opts),
            case is_map(Balances) of
                true -> canonicalize_balances(Base, Balances, Opts);
                false -> {ok, Base}
            end
    end.

canonicalize_balances(Base, Balances, Opts) ->
    {Changed, FlatBalances} =
        lists:foldl(
            fun(Key, {ChangedAcc, BalancesAcc}) ->
                Account = account_key(Key),
                {ok, Amount} = hb_ao:resolve(Balances, Key, Opts),
                {
                    ChangedAcc
                        orelse (Account =/= Key)
                        orelse maps:is_key(Account, BalancesAcc),
                    add_balance(Account, Amount, BalancesAcc)
                }
            end,
            {false, #{}},
            lib_trie:keys(Balances, Opts)
        ),
    case Changed of
        false ->
            {ok, Base};
        true ->
            {ok, NewBalances} =
                hb_ao:resolve(
                    #{<<"device">> => <<"trie@1.0">>},
                    FlatBalances#{<<"path">> => <<"set">>},
                    Opts
                ),
            {ok, hb_maps:put(<<"balances">>, NewBalances, Base, Opts)}
    end.

%% @doc Entrypoint for computations on token processes. Deduplicates by signed
%% assignment body, then expects the `action' key to hold the `path' to execute
%% after enforcing the token's security constraints. Always returns the base
%% state unmodified in the event of downstream device errors, such that invalid
%% interactions do not result in invalid `~process@1.0' states.
compute(Base, Assignment, Opts) ->
    ?event({token_call, Assignment}),
    case deduplicate(Base, Assignment, Opts) of
        {skip, DedupedBase} ->
            ?event(token_short, {skipping_duplicate_assignment, Assignment}, Opts),
            {ok, DedupedBase};
        {ok, DedupedBase} ->
            maybe
                {ok, SecureReq} ?= enforce_security(DedupedBase, Assignment, Opts),
                {ok, Action} ?= hb_ao:resolve(Assignment, <<"body/action">>, Opts),
                {ok, Res} ?= handle_action(Action, DedupedBase, SecureReq, Opts),
                ?event(debug_token, {route_result, Res}, Opts),
                {ok, Res}
            else
                {error, Reason} ->
                    ?event(token_short, {error_during_token_call, Reason}, Opts),
                    send_error(Base, Assignment, Reason, Opts)
            end;
        {error, Reason} ->
            ?event(token_short, {error_during_token_dedup, Reason}, Opts),
            send_error(Base, Assignment, Reason, Opts)
    end.

%% @doc Deduplicate token computations by the signed assignment body. Replayed
%% assignments get fresh slots, so the assignment itself cannot be the subject.
deduplicate(Base, Assignment, Opts) ->
    BaseDevice = hb_maps:get(<<"device">>, Base, not_found, Opts),
    case hb_ao:resolve(Base, {as, <<"dedup@1.0">>, Assignment}, Opts) of
        {Status, DedupedBase} when Status =:= ok; Status =:= skip ->
            {Status, restore_device(BaseDevice, DedupedBase, Opts)};
        Error ->
            Error
    end.

restore_device(not_found, Base, _Opts) ->
    Base;
restore_device(Device, Base, Opts) ->
    hb_ao:set(Base, <<"device">>, Device, Opts).

%% @doc Enforce the security constraints of the base state upon the request.
enforce_security(Base, Req, Opts) ->
    case lib_process:run_as(<<"security">>, Base, Req, Opts) of
        {ok, SecureReq} -> {ok, SecureReq};
        {skip, Reason} -> {error, Reason}
    end.

%% @doc Route the request to the appropriate key resolution function, depending
%% upon the `action' specified.
handle_action(Action, Base, Req, Opts) ->
    Self = lib_process:process_id(Base, #{}, Opts),
    ?event(token_short, {token, {id, Self}, {action, Action}}, Opts),
    case hb_util:to_lower(hb_ao:normalize_key(Action)) of
        <<"transfer">> -> transfer(Base, Req, Opts);
        <<"set">> -> secure_set(Base, Req, Opts);
        <<"subscribe">> -> lib_process_outbox:subscribe(Base, Req, Opts);
        <<"unsubscribe">> -> lib_process_outbox:unsubscribe(Base, Req, Opts);
        MintDevAction -> action_as_mint_device(MintDevAction, Base, Req, Opts)
    end.

%% @doc Get the balance for an account. Normalize the minting state for that
%% account before returning.
balance(Base, Req, Opts) ->
    maybe
        {ok, Account0} ?= hb_ao:resolve(Req, <<"balance">>, Opts),
        true ?= validate_address(Account0, []),
        Account = account_key(Account0),
        ?event(
            debug_token,
            {balance_request,
                {account, Account0},
                {canonical_account, Account},
                {base, Base}
            },
            Opts
        ),
        {ok, NormBase} ?=
            normalize_mint(
                Base,
                hb_ao:set(Req, <<"subject">>, Account, Opts),
                Opts
            ),
        BalanceRes =
            hb_ao:resolve_many(
                [
                    NormBase,
                    <<"balances">>,
                    Account
                ],
                Opts
            ),
        ?event(
            debug_token,
            {balance_after_mint_normalization,
                {account, Account},
                {balance, BalanceRes}
            },
            Opts
        ),
        case BalanceRes of
            {ok, Balance} -> {ok, Balance};
            {error, not_found} -> {ok, 0};
            {error, Reason} -> {error, Reason}
        end
    end.

transfer(Base, Assignment, Opts) ->
    maybe
        % Gather transfer data from the request.
        {ok, Req} ?= hb_ao:resolve(Assignment, <<"body">>, Opts),
        {ok, From0} ?= hb_ao:resolve(Req, <<"from">>, Opts),
        {ok, Recipient0} ?= hb_ao:resolve(Req, <<"recipient">>, Opts),
        {ok, Quantity} ?= hb_ao:resolve(Req, <<"quantity">>, Opts),
        % validate From/Recipient sanity
        true ?= validate_address(From0, []),
        true ?= validate_address(Recipient0, []),
        From = account_key(From0),
        Recipient = account_key(Recipient0),
        % Normalize the base's minting state for the sender.
        {ok, NormBase} ?=
            normalize_mint(
                Base,
                Assignment#{ <<"subject">> => From },
                Opts
            ),
        % Retrieve balances from the base state.
        Balances = hb_ao:get(<<"balances">>, NormBase, Opts),
        ?event(debug_token, {balances_before_transfer, Balances}, Opts),
        SenderBalance = hb_ao:get(From, Balances, 0, Opts),
        RecipientBalance = hb_ao:get(Recipient, Balances, 0, Opts),
        ?event(
            debug_token,
            {transfer_balances, 
                {from, From}, 
                {to, Recipient},
                {quantity, Quantity},
                {sender_balance, SenderBalance},
                {recipient_balance, RecipientBalance}
            },
            Opts
        ),
        % Sanity check the transfer request.
        true ?= (is_integer(SenderBalance) and is_integer(RecipientBalance)
                and (SenderBalance >= 0) and (RecipientBalance >= 0))
            orelse {error, <<"Invalid balance values.">>},
        true ?= (is_integer(Quantity) and (Quantity >= 0))
            orelse {error, <<"Quantity must be a non-negative integer.">>},
        true ?= (SenderBalance >= Quantity) 
            orelse {error, <<"Insufficient balance.">>},
        % Handle self-transfer: skip balance updates
        NewBaseAfterTransfer =
            case From =:= Recipient of
                true -> NormBase;
                false ->
                    {ok, NewBalances} =
                        hb_ao:resolve(
                            Balances,
                            #{
                                <<"path">> => <<"set">>,
                                From => SenderBalance - Quantity,
                                Recipient => RecipientBalance + Quantity
                            },
                            Opts
                        ),
                    hb_maps:put(<<"balances">>, NewBalances, NormBase, Opts)
            end,
        % Send transfer notices.
        WithNotices = lib_process_outbox:send(
            transfer_notices(From0, Recipient0, Quantity, Req, Opts),
            NewBaseAfterTransfer,
            Opts
        ),
        {ok, WithNotices}
    else
        {error, Reason} ->
            ?event(token_short, {ignoring_errored_transfer, Reason}, Opts),
            ?event(debug_token,
                {errored_transfer,
                    {reason, Reason},
                    {returning_base, Base}
                },
                Opts
            ),
            send_error(Base, Assignment, Reason, Opts)
    end.

transfer_notices(From, Recipient, Quantity, Req, Opts) ->
    % Extract forwarded keys (X- prefixed fields from request)
    ForwardedKeys = lib_process_outbox:forwarded_keys(Req, Opts),
    DebitNotice =
        ForwardedKeys#{
            <<"action">> => <<"Debit-Notice">>,
            <<"recipient">> => Recipient,    
            <<"quantity">> => Quantity,
            <<"target">> => From              
        },
    CreditNotice =
        ForwardedKeys#{
            <<"target">> => Recipient,       
            <<"action">> => <<"Credit-Notice">>,
            <<"sender">> => From,             
            <<"quantity">> => Quantity
        },
    [DebitNotice, CreditNotice].

%%% Mint device orchestration.

%% @doc Call the mint device's main entrypoint, allowing it to handle explicit
%% mint requests, normalize its state (prior to `transfer`s, etc), or ignore
%% the request altogether. If a public token `mint` request includes
%% `body.subject`, hoist it to the top-level request shape expected by the mint
%% device before dispatch.
mint(Base, Assignment, Opts) ->
    case hb_ao:resolve(Assignment, <<"body">>, Opts) of
        {error, _} ->
            as_mint_device(<<"mint">>, Base, Assignment, Opts);
        {ok, Req} ->
            case hb_maps:find(<<"subject">>, Req, Opts) of
                error ->
                    as_mint_device(<<"mint">>, Base, Assignment, Opts);
                {ok, Subject} ->
                    maybe
                        true ?= validate_address(Subject, []),
                        MintReq1 =
                            hb_ao:set(
                                Assignment,
                                <<"subject">>,
                                account_key(Subject),
                                Opts
                            ),
                        as_mint_device(<<"mint">>, Base, MintReq1, Opts)
                    end
            end
    end.

%% @doc Execute the mint device's main key, but return the state in its 
%% unmodified form if the execution returns an error.
normalize_mint(Base, Assignment, Opts) ->
    try mint(Base, Assignment, Opts) of
        {ok, NewBase} -> {ok, NewBase};
        {error, _} -> {ok, Base}
    catch
        throw:{error, {device_not_loadable, _Device, _Reason}} ->
            {ok, Base}
    end.

%% @doc Check if the action is supported by the mint device interface.
is_supported_mint_action(Action) ->
    lists:member(Action, ?MINT_ACTIONS).

%% @doc Verify if the action is a supported path on the mint device interface,
%% and if so, switch to the mint device and run it. Unsupported actions fall through
%% send_error/4 codepath.
action_as_mint_device(Action, Base, Req, Opts) ->
    case hb_ao:get(<<"mint-device">>, Base, undefined, Opts) of
        undefined ->
            send_error(Base, Req, <<"mint-device not configured">>, Opts);
        _ ->
            case is_supported_mint_action(Action) of
                true when Action =:= <<"mint">> -> mint(Base, Req, Opts);
                true -> as_mint_device(Action, Base, Req, Opts);
                false ->
                    ?event(error, {unsupported_token_action, Action}, Opts),
                    send_error(Base, Req, <<"unsupported action: ", Action/binary>>, Opts)
            end
    end.

%% @doc Run a given `path' on the mint device.
as_mint_device(Path, Base, Req, Opts) ->
    lib_process:run_as(
        <<"mint">>,
        ensure_mint_device(Base, Opts),
        Req#{ <<"path">> => Path },
        Opts
    ).

%% @doc Add the default mint device if none is present already.
ensure_mint_device(Base, Opts) ->
    hb_ao:set(
        Base,
        #{
            <<"mint-device">> =>
                hb_ao:get(
                    <<"mint-device">>,
                    Base,
                    <<"mint-authority@1.0">>,
                    Opts
                )
        },
        Opts
    ).

%%% Secure `set' call orchestration.

%% @doc Ensure that the caller is the `set' authority, and apply changes to the
%% base state if so. The setter can only mutate whitelisted fields.
secure_set(Base, Assignment, Opts) ->
    maybe
        {ok, Req} ?= hb_ao:resolve(Assignment, <<"body">>, Opts),
        true ?= enforce_set_authority(Base, Req, Opts),
        RawBody = hb_maps:get(<<"body">>, Assignment, #{}, Opts),
        SetReq =
            hb_maps:without(
                [<<"from">>, <<"action">>, <<"path">>],
                RawBody,
                Opts
            ),
        % Check the auth is touching whitelisted fields only.
        true ?= enforce_whitelisted_fields(Base, SetReq, Opts),
        % Apply updates to base state.
        hb_ao:resolve(Base, Req#{ <<"path">> => <<"set">> }, Opts)
    end.
enforce_whitelisted_fields(Base, Req, Opts) ->
    maybe
        Keys = hb_maps:keys(Req, Opts),
        WhitelistedFields = whitelisted_auth_fields(Base, Opts),
        true ?= is_list(WhitelistedFields) orelse
                    {error, <<"Invalid `whitelisted-fields` type.">>},
        case lists:member(<<"*">>, WhitelistedFields) of
            true ->
                true;
            false ->
                case lists:all(
                    fun(Key) -> lists:member(Key, WhitelistedFields) end,
                    Keys
                ) of
                    true -> true;
                    false -> {error, <<"Attempted to set non-whitelisted fields.">>}
                end
            end
    end.

%% @doc Enforce that the caller is the `set` authority. If `Base` configures
%% either `set-authority-required` or `set-authority-match`, this function
%% delegates authorization to `dev_security:validate/5` for `set-authority`.
%% Otherwise it falls back to legacy exact-match semantics:
%% `Req/from =:= Base/set-authority`.
enforce_set_authority(Base, Req, Opts) ->
    maybe
        Setter = hb_ao:get(<<"from">>, Req, Opts),
        true ?= (Setter =/= not_found) orelse
                {error, <<"Setter not found.">>},
        SetAuthorityRequired =
            hb_ao:get(<<"set-authority-required">>, Base, not_found, Opts),
        SetAuthorityMatch =
            hb_ao:get(<<"set-authority-match">>, Base, not_found, Opts),
        AuthRes = case
            (SetAuthorityRequired =/= not_found)
            orelse
            (SetAuthorityMatch =/= not_found)
        of
            true ->
                security_validate(
                    <<"set-authority">>,
                    Base,
                    Req,
                    Setter,
                    Opts
                );
            false ->
                enforce_legacy_set_authority(Setter, Base, Opts)
        end,
        true ?= AuthRes
    end.

enforce_legacy_set_authority(Setter, Base, Opts) ->
    case validate_address(Setter, []) of
        true ->
            SetAuthority = hb_ao:get(<<"set-authority">>, Base, Opts),
            case SetAuthority of
                not_found ->
                    {error, <<"SetAuthority not found.">>};
                _ ->
                    case {Setter, SetAuthority} of
                        {S, S} ->
                            true;
                        _ ->
                            {error, <<"Caller is not the `set-authority'.">>}
                    end
            end;
        {error, _} = Err ->
            Err
    end.

%%% Helper functions.

%% @doc Validate address format for security. the validation
%% allows binary addresses up to 128 bytes and prevent invalid
%% addresses such as lib_trie reserved keys.
validate_address(Address, CustomList) when is_binary(Address), is_list(CustomList) ->
    ReservedKeys = ?AO_RESERVED_ADDRESS_KEYS ++ CustomList,
    AccountKey = account_key(Address),
    CanonicalReservedKeys = [account_key(Key) || Key <- ReservedKeys, is_binary(Key)],
    case byte_size(Address) of
        0 -> {error, <<"Address cannot be empty.">>};
        N when N > 128 -> {error, <<"Address is too long.">>};
        _ ->
            maybe
                true ?= (not lib_trie:is_reserved_key(Address))
                    orelse {error, <<"Address uses a reserved trie internal key.">>},
                true ?= (not lib_trie:is_reserved_key(AccountKey))
                    orelse {error, <<"Address uses a reserved trie internal key.">>},
                true ?= (not is_reserved_custom_key(Address, ReservedKeys))
                    orelse {error, <<"Address is a reserved ao/custom key">>},
                true ?= (not is_reserved_custom_key(AccountKey, CanonicalReservedKeys))
                    orelse {error, <<"Address is a reserved ao/custom key">>},
                % Check for path separators (security: prevent path traversal) and whitespaces.
                case binary:match(Address, [<<"/">>, <<"\\">>, <<" ">>, <<"\n">>, <<"\r">>, <<"\t">>]) of
                    nomatch -> true;
                    _ -> {error, <<"Address cannot contain path separators or whitespaces">>}
                end
            end
    end;
validate_address(_, _) ->
    {error, <<"Address must be a binary.">>}.

account_key(Address) when is_binary(Address) ->
    hb_util:to_lower(Address).

add_balance(Account, Amount, Balances) ->
    Balances#{ Account => maps:get(Account, Balances, 0) + Amount }.

%% @doc Check if the given Key exists in the passed List
is_reserved_custom_key(Key, List) when is_binary(Key), is_list(List) ->
    lists:member(Key, List);
is_reserved_custom_key(_, _) -> 
    false.

security_validate(Key, Base, SubjectMsg, From, Opts) ->
    {ok, Security} = hb_device_load:reference(<<"security@1.0">>, Opts),
    Security:validate(Key, Base, SubjectMsg, From, Opts).

send_error(Base, Assignment, Reason, Opts) when is_atom(Reason) ->
    send_error(Base, Assignment, atom_to_binary(Reason), Opts);
send_error(Base, Assignment, Reason, Opts) when not is_binary(Reason) ->
    send_error(
        Base,
        Assignment,
        iolist_to_binary(io_lib:format("~0p", [Reason])),
        Opts
    );
send_error(Base, Assignment, Reason, Opts) when is_binary(Reason) ->
    case hb_ao:resolve(Assignment, <<"body/from">>, Opts) of
        {error, Error} ->
            ?event(token_short, {skipping_error_report, Error}, Opts),
            {ok, Base};
        {ok, Target} ->
            {ok,
                lib_process_outbox:send(
                    #{
                        <<"target">> => Target,       
                        <<"reason">> => Reason
                    },
                    Base,
                    Opts
                )
            }
    end.
