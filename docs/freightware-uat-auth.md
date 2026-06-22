# FreightWare UAT authentication

## Status (2026-06-22)

Authentication against the internal UAT is **credential-correct but blocked by a
server-side config gap**:

- Endpoint reachable, IP whitelisted, path correct.
- Username + password + station are accepted (no 401).
- Login then fails with **HTTP 400 — `** No gsc_language record is available. (91)`**,
  *after* auth and branch validation. No `X-FreightWare` token is issued.

This is a **Dovetail/FreightWare backend fix** — the `gsc_language` master record
is empty on the `:5001` UAT instance. No request parameter changes it.

## Note for Dovetail

> On the UAT instance `http://tragar-db.dovetail.co.za:5001/WebServices/web`, the
> login call authenticates the `TragarWeb` user (JHB branch) but returns:
>
> ```
> POST /FreightWare/V2/system/auth/login
> {"request":{"username":"TragarWeb","password":"***","station":"JHB"}}
>
> HTTP/1.1 400
> {"response":{"esErrors":{"Errors":[
>   {"errorCode":"400","errorDescription":"** No gsc_language record is available. (91)"}]}}}
> ```
>
> Branch validation works (e.g. `station=CPT` correctly returns *"No valid branch
> associated with this user"*), so this is the language master data missing for
> this environment. Please populate the `gsc_language` record on UAT so the
> session can complete and issue an `X-FreightWare` token.

## Verifying once it's fixed

Credentials are **not** stored in the repo — pass them via env:

```bash
DOVETAIL_BASE_URL=http://tragar-db.dovetail.co.za:5001/WebServices/web \
DOVETAIL_USERNAME=TragarWeb DOVETAIL_PASSWORD=*** DOVETAIL_STATION=JHB \
mix tragar.fw_auth
```

Expected on success: `OK — authenticated. token=…`. Then a live read can be
pulled (e.g. `TragarAi.Freight.get_waybill("4821")`) and the FreightWare adapter
taken out of demo mode.
