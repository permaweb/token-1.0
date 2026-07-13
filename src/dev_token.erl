%%% @doc A fast, simple implementation of AO token specification.
%%% Specification: https://cookbook_ao.arweave.net/references/api/token.html
-module(dev_token).
-export([
    info/0,
    route/4,
    compute/3,
    init/3,
    normalize/3,
    snapshot/3,
    balance/3,
    mint/3
]).
%%% Non-public device API functions. Note: Ensure that these are not exported.
-export([handle_action/4]).
-include_lib("hb/include/hb.hrl").

-implements(<<"token@1.0">>).
-device_libraries([lib_token]).

-define(PROCESS_OUTBOX_DEVICE, <<"process-outbox@1.0">>).

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
%% @doc Root-level request envelope/control keys that must never become token
%% state through `Set'. Authority checks still see the original request.
-define(SET_CONTROL_KEYS,
    [
        <<"from">>,
        <<"action">>,
        <<"path">>,
        <<"body">>,
        <<"commitments">>,
        <<"committers">>,
        <<"ao-types">>,
        <<"target">>,
        <<"type">>,
        <<"id">>,
        <<"timestamp">>,
        <<"variant">>,
        <<"data-protocol">>,
        <<"set-mode">>,
        <<"priv">>,
        <<"hashpath">>
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

%% @doc Return the public token device API. All resolutions pass through
%% `route/4' so scheduled assignments cannot use the message-device fallback
%% to execute a state path directly.
info() ->
    #{ handler => fun route/4 }.

%% @doc Route token calls. Scheduler assignments are state transitions and
%% must enter through exactly `/compute'; lifecycle calls and ordinary reads
%% retain the existing public device behavior.
route(Key, Base, Req, Opts) ->
    case is_assignment(Req, Opts) andalso not is_compute_path(Req, Opts) of
        true ->
            ?event(
                token_short,
                {ignoring_non_compute_assignment,
                    {path, hb_path:from_message(request, Req, Opts)}},
                Opts
            ),
            {ok, Base};
        false ->
            NormKey = hb_util:to_lower(hb_ao:normalize_key(Key)),
            route_allowed(NormKey, Key, Base, Req, Opts)
    end.

route_allowed(<<"compute">>, _Key, Base, Req, Opts) -> compute(Base, Req, Opts);
route_allowed(<<"init">>, _Key, Base, Req, Opts) -> init(Base, Req, Opts);
route_allowed(<<"normalize">>, _Key, Base, Req, Opts) -> normalize(Base, Req, Opts);
route_allowed(<<"snapshot">>, _Key, Base, Req, Opts) -> snapshot(Base, Req, Opts);
route_allowed(<<"balance">>, _Key, Base, Req, Opts) -> balance(Base, Req, Opts);
route_allowed(<<"mint">>, _Key, Base, Req, Opts) -> mint(Base, Req, Opts);
route_allowed(_NormKey, Key, Base, Req, Opts) ->
    hb_ao:raw(<<"message@1.0">>, Key, Base, Req, Opts).

is_assignment(Req, Opts) ->
    case hb_maps:get(<<"type">>, Req, undefined, Opts) of
        undefined ->
            is_assignment_envelope(Req);
        Type ->
            hb_path:matches(Type, <<"assignment">>) orelse
                is_assignment_envelope(Req)
    end.

is_assignment_envelope(Req) when is_map(Req) ->
    maps:is_key(<<"slot">>, Req) andalso
        maps:is_key(<<"process">>, Req) andalso
        maps:is_key(<<"body">>, Req);
is_assignment_envelope(_Req) ->
    false.

is_compute_path(Req, Opts) ->
    case hb_path:from_message(request, Req, Opts) of
        [Path] -> hb_path:matches(Path, <<"compute">>);
        _ -> false
    end.

%% @doc Canonicalize account keys in the initial balance trie.
init(Base, _Req, Opts) ->
    canonicalize_balances(Base, Opts).

%% @doc No-op on normalization.
normalize(Base, _Req, _Opts) ->
    {ok, Base}.

%% @doc No special processing for the creation of snapshots.
snapshot(Base, _Req, _Opts) ->
    {ok, Base}.

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
                case lib_token:validate_address(Key, [], Opts) of
                    true ->
                        Account = lib_token:account_key(Key),
                        case hb_ao:resolve(Balances, Key, Opts) of
                            {ok, Amount} when is_integer(Amount) ->
                                {
                                    ChangedAcc
                                        orelse (Account =/= Key)
                                        orelse maps:is_key(Account, BalancesAcc),
                                    add_balance(Account, Amount, BalancesAcc)
                                };
                            _ ->
                                {ChangedAcc, BalancesAcc}
                        end;
                    {error, _} ->
                        {ChangedAcc, BalancesAcc}
                end
            end,
            {false, #{}},
            trie_keys(Balances, Opts)
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
    SecurityDevice = hb_maps:get(
        <<"security-device">>,
        Base,
        <<"security@1.0">>,
        Opts
    ),
    case run_as_device(<<"security">>, SecurityDevice, Base, Req, Opts) of
        {ok, SecureReq} -> {ok, SecureReq};
        {skip, Reason} -> {error, Reason}
    end.

%% @doc Route the request to the appropriate key resolution function, depending
%% upon the `action' specified.
handle_action(Action, Base, Req, Opts) ->
    ?event(token_short, {token_action, Action}, Opts),
    case hb_util:to_lower(hb_ao:normalize_key(Action)) of
        <<"transfer">> -> transfer(Base, Req, Opts);
        <<"set">> -> secure_set(Base, Req, Opts);
        <<"subscribe">> -> outbox_subscribe(Base, Req, Opts);
        <<"unsubscribe">> -> outbox_unsubscribe(Base, Req, Opts);
        MintDevAction -> action_as_mint_device(MintDevAction, Base, Req, Opts)
    end.

%% @doc Get the balance for an account. Normalize the minting state for that
%% account before returning.
balance(Base, Req, Opts) ->
    maybe
        {ok, Account0} ?= hb_ao:resolve(Req, <<"balance">>, Opts),
        true ?= lib_token:validate_address(Account0, [], Opts),
        Account = lib_token:account_key(Account0),
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
        true ?= transfer_enabled(Base, Opts),
        % validate From/Recipient sanity
        true ?= lib_token:validate_address(From0, [], Opts),
        true ?= lib_token:validate_address(Recipient0, [], Opts),
        From = lib_token:account_key(From0),
        Recipient = lib_token:account_key(Recipient0),
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
        {ok, WithNotices} ?= outbox_send(
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

transfer_enabled(Base, Opts) ->
    Default = hb_opts:get(<<"transfer-enabled">>, true, Opts),
    case hb_ao:get(<<"transfer-enabled">>, Base, Default, Opts) of
        true -> true;
        false -> {error, <<"Transfers are disabled.">>};
        _ -> {error, <<"Invalid `transfer-enabled` type.">>}
    end.

transfer_notices(From, Recipient, Quantity, Req, Opts) ->
    % Extract forwarded keys (X- prefixed fields from request)
    ForwardedKeys = forwarded_keys(Req, Opts),
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
    case mint_enabled(Base, Opts) of
        true -> mint_request(Base, Assignment, Opts);
        Error -> Error
    end.

mint_request(Base, Assignment, Opts) ->
    case hb_ao:resolve(Assignment, <<"body">>, Opts) of
        {error, _} ->
            as_mint_device(<<"mint">>, Base, Assignment, Opts);
        {ok, Req} ->
            case hb_maps:find(<<"subject">>, Req, Opts) of
                error ->
                    as_mint_device(<<"mint">>, Base, Assignment, Opts);
                {ok, Subject} ->
                    maybe
                        true ?= lib_token:validate_address(Subject, [], Opts),
                        MintReq1 =
                            hb_ao:set(
                                Assignment,
                                <<"subject">>,
                                lib_token:account_key(Subject),
                                Opts
                            ),
                        as_mint_device(<<"mint">>, Base, MintReq1, Opts)
                    end
            end
    end.

mint_enabled(Base, Opts) ->
    Default = hb_opts:get(<<"mint-enabled">>, true, Opts),
    case hb_ao:get(<<"mint-enabled">>, Base, Default, Opts) of
        true -> true;
        false -> {error, <<"Minting is disabled.">>};
        _ -> {error, <<"Invalid `mint-enabled` type.">>}
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
    MintBase = ensure_mint_device(Base, Opts),
    MintDevice = hb_ao:get(<<"mint-device">>, MintBase, Opts),
    run_as_device(
        <<"mint">>,
        MintDevice,
        MintBase,
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
        Req = hb_maps:get(<<"body">>, Assignment, not_found, Opts),
        true ?= is_map(Req) orelse {error, <<"Set body must be a message.">>},
        true ?= enforce_set_authority(Base, Req, Opts),
        Mutation = set_mutation_fields(Req, Opts),
        % Check the auth is touching whitelisted fields only.
        true ?= enforce_whitelisted_fields(Base, Mutation, Opts),
        % Apply updates to base state.
        hb_ao:resolve(Base, Mutation#{ <<"path">> => <<"set">> }, Opts)
    end.

set_mutation_fields(Req, Opts) ->
    hb_maps:without(?SET_CONTROL_KEYS, Req, Opts).

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

%% @doc Enforce that the caller is the `set` authority. The configured security
%% device owns both static signer-set and dynamic ownership semantics.
enforce_set_authority(Base, Req, Opts) ->
    maybe
        Setter = hb_ao:get(<<"from">>, Req, Opts),
        true ?= (Setter =/= not_found) orelse
                {error, <<"Setter not found.">>},
        AuthRes =
            security_validate(
                <<"set-authority">>,
                Base,
                Req,
                Setter,
                Opts
            ),
        true ?= AuthRes
    end.

%%% Helper functions.

trie_keys(Balances, Opts) ->
    {ok, Trie} = hb_device_load:reference(<<"trie@1.0">>, Opts),
    Trie:keys(Balances, Opts).

add_balance(Account, Amount, Balances) ->
    Balances#{ Account => maps:get(Account, Balances, 0) + Amount }.

outbox_send(Messages, Base, Opts) ->
    maybe
        {ok, Outbox} ?= process_outbox(Opts),
        Outbox:send(
            Base,
            #{ <<"messages">> => Messages },
            Opts
        )
    end.

outbox_subscribe(Base, Req, Opts) ->
    maybe
        {ok, Outbox} ?= process_outbox(Opts),
        Outbox:subscribe(Base, Req, Opts)
    end.

outbox_unsubscribe(Base, Req, Opts) ->
    maybe
        {ok, Outbox} ?= process_outbox(Opts),
        Outbox:unsubscribe(Base, Req, Opts)
    end.

process_outbox(Opts) ->
    case hb_device_load:reference(?PROCESS_OUTBOX_DEVICE, Opts) of
        {ok, Outbox} ->
            {ok, Outbox};
        {error, Reason} ->
            {error, {process_outbox_not_loadable, Reason}}
    end.

forwarded_keys(Req, Opts) ->
    hb_maps:filter(
        fun(Key, _Value) ->
            KeyBin = hb_util:to_lower(hb_util:bin(Key)),
            binary:match(KeyBin, <<"x-">>) =:= {0, 2}
        end,
        Req,
        Opts
    ).

security_validate(Key, Base, _SubjectMsg, From, Opts) ->
    SecurityDevice = hb_maps:get(
        <<"security-device">>,
        Base,
        <<"security@1.0">>,
        Opts
    ),
    % `From' has already been normalized by `security@1.0' in the compute path.
    % Do not pass the Set body back as a validation subject: root keys such as
    % `path' are user mutation data here and must not affect security routing.
    ValidateReq = #{
        <<"path">> => <<"validate">>,
        <<"key">> => Key,
        <<"from">> => From
    },
    case run_as_device(<<"security">>, SecurityDevice, Base, ValidateReq, Opts) of
        {ok, true} -> true;
        {error, Reason} -> {error, Reason};
        {skip, Reason} -> {error, Reason};
        Other -> {error, {security_validate_unexpected_result, Other}}
    end.

run_as_device(Key, Device, Base, Path, Opts) when not is_map(Path) ->
    run_as_device(Key, Device, Base, #{ <<"path">> => Path }, Opts);
run_as_device(Key, Device, Base, Req, Opts) ->
    BaseDevice = hb_maps:get(<<"device">>, Base, not_found, Opts),
    {ok, PreparedMsg} =
        hb_ao:resolve(
            ensure_process_key(Base, Opts),
            #{
                <<"path">> => <<"set">>,
                <<"device">> => Device,
                <<"input-prefix">> =>
                    case hb_maps:get(<<"input-prefix">>, Base, not_found, Opts) of
                        not_found -> <<"process">>;
                        Prefix -> Prefix
                    end,
                <<"output-prefixes">> =>
                    hb_maps:get(
                        <<Key/binary, "-output-prefixes">>,
                        Base,
                        undefined,
                        Opts
                    )
            },
            Opts
        ),
    {Status, BaseResult} = hb_ao:resolve(PreparedMsg, Req, Opts),
    case {Status, BaseResult} of
        {ok, #{ <<"device">> := Device }} ->
            {ok, hb_ao:set(BaseResult, #{ <<"device">> => BaseDevice }, Opts)};
        _ ->
            {Status, BaseResult}
    end.

ensure_process_key(Base, Opts) ->
    case hb_maps:get(<<"process">>, Base, not_found, Opts) of
        not_found ->
            {ok, Committed} = hb_message:with_only_committed(Base, Opts),
            hb_ao:set(
                hb_message:uncommitted(Base, Opts),
                #{ <<"process">> => Committed },
                Opts#{ <<"hashpath">> => ignore }
            );
        _ ->
            Base
    end.

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
            outbox_send(
                #{
                    <<"target">> => Target,
                    <<"reason">> => Reason
                },
                Base,
                Opts
            )
    end.
