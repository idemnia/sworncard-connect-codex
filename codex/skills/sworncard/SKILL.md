---
name: sworncard
description: Use Sworncard Connect to discover services, guide passport and service setup, and perform supported passport-authorized reads. Use when the user names Sworncard or requests an operation through its configured MCP server.
---

Use the tools actually exposed by the configured Sworncard Connect MCP server.
Its PAT selects the connection; a platform name or keyword cannot change its
owner or permissions. Never ask for a PAT in chat, inspect local credentials, or
put tokens in tool arguments. If multiple configured connections could satisfy
the request and the intended personal/work context is unclear, ask which to use.

For “покажи баланс в Мостлайн”, “через Sworncard”, or “show my Mostline balance”:

1. Read the published tool schemas and `list_connections` result. Match the
   registered service identity and supported operation, not just a similar name.
   An unavailable or incomplete catalogue does not prove a service is unsupported.
   Do not invent absent tools or arguments.
2. Call `list_operations(serviceId)` for that registered service. Select the exact
   operationId and read its argument/result schema. An active ownerLinkState is
   not a passport; canStart describes the service link, not passport issuance.
   Discovery describes available integrations, not permission to execute.
3. Call `execute_operation(serviceId, operationId, arguments, requestId)` with
   arguments matching the selected schema and a new lowercase UUIDv4 requestId.
   Preserve the entire pair, arguments and ID on a transport retry. Only `allowed`
   contains verified data; interpret it according to that operation's resultSchema.
   For Mostline get_balance, report balance_rub and reserved_rub in rubles.
   On `setup_required` / `passport_missing`, follow `start_service_setup` below.
   On `setup_pending`, call `get_service_setup` with the returned setupId; do not
   use the unexecuted business requestId as a setup locator. Human confirmation
   and a repeated command are required; do not create a passport silently.
   For `denied`, convey the refusal. For `unknown` or `unverified_result`, say the
   result could not be confirmed. To check an earlier request, call
   `get_operation_status(serviceId, operationId, requestId)` once, without arguments.
   This is historical data, not a fresh read. On `not_found` or `conflict`, explain
   and wait for the user's next request. Never mint an ID to bypass uncertainty,
   poll automatically, fall back to another API, or invent target-specific tools.
   On `invalid_arguments`, check the published schema; do not claim execution.
   On `operation_unavailable`, refresh discovery once and explain the limitation.
4. For a service outside the supported catalogue, or a `registered_only` service
   whose Connect adapter is not yet admitted, use the available `request_service`
   tool. Submit only the service name/alias or exact service ID in `serviceLabel`;
   an optional domain is a hostname, not a URL. Do not submit the business prompt,
   contact details or credentials. A new user request gets a new UUIDv4 requestId;
   a transport retry preserves the same ID and inputs. Confirm recording only on
   `recorded` or `already_recorded`. If the tool is absent or fails, recording is
   unconfirmed. Do not promise when the service will be integrated.

For a supported service requiring setup:

- Call `start_service_setup` with its serviceId and a new canonical lowercase
  UUIDv4 requestId. Keep both values for this setup; retries, including after PAT
  replacement, use the same values. A new ID does not bypass an unfinished setup.
- If the start response is lost, call `get_service_setup` with the original
  requestId. With a known setupId, pass only setupId. Never pass both locators or
  add owner, connection, platform, URL or rights arguments.
- Follow the returned nextStep. For `preparing`, retry the same start request
  once in this turn. If it is still pending, report that state; if it fails,
  apply the status-first rule below. Do not loop or create a new request.
  For `awaiting_user`, show the returned entryUri and setupExpiresAt together:
  “Завершите настройку по ссылке. Затем отправьте исходную команду ещё раз.”
  The expiry is for this setup, not for the passport or PAT.
- `awaiting_completion` means completion has not been confirmed. Check status on
  the user's next request, not periodically. Do not hold a tool call open while
  the person completes the browser flow or run the business read in background.
- `complete` is confirmed historical setup, not current permission. After a
  setup/status-only request, ask the user to repeat the original command. If
  this turn already is that repeated business request, use the selected generic
  operation with fresh checks; do not ask for another repetition.
  `passportReceived=true` alone does not mean setup is complete.
- For `setup_in_progress`, read the returned own setupId and explain the pending
  setup. If it is known to be a previously opened passport ceremony, ask the user
  to finish that ceremony; do not invent a new link or infer this from an error
  alone. For `setup_unavailable`, refresh discovery and check the known request's
  status; if no saved setup exists, direct the user to support. Do not label the
  service unsupported or start again with a new ID.
  `setup_not_found` after a lost start permits retrying the original start, with
  the same ID and service. A conflicting ID is not retried with changed inputs.
- For `temporarily_unavailable` from start, read status once; if status itself
  is unavailable, report the unknown outcome without looping. A failed response
  does not prove nothing was created.
- When a business request leads to `get_service_setup` and the result is
  `recovery_needed` with `retry_start_same_request`, call `start_service_setup`
  once **in this turn** for the returned serviceId. The business request itself
  asks to use the service, even in a new chat. Use the original setup requestId
  if known, otherwise a fresh UUIDv4. Show the confirmed entryUri and
  setupExpiresAt in the same chat. Ask the user to repeat the business request
  after they finish setup in Idemnia. For a status-only question, report the
  saved state. If the start returns `contact_support` or `recovery_required`,
  explain the state and direct the user to support.

Forward any recovery notice: the user should check their PATs after restoration.
It does not itself require a new passport, forced PAT replacement, or extra
consent. Honor any separate current-authority refusal returned by the operation.

Authentication failures lead back to the Idemnia cabinet/client setup. PAT
replacement preserves the connection and passports; deleting the connection
blocks the PAT and revokes its passports. Removing this plugin only removes the
local integration; it does not revoke remote access.

Pilot contract update: the old mostline_get_balance tool is removed. Existing
MCP URL and PAT stay the same. If the client caches the old tool list, refresh
its connection/session. Never recreate a connection or passport for this update.
