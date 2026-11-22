# Codex notifications

Treelab's Codex defaults reduce interruptions: end-of-answer events no longer raise an alert,
while permission requests and questions are still reported.
A preference already saved is kept, including an "always" choice or a disabled alert.
The defaults only add missing keys, and the file is backed up before any change.
They are written by `codex_notification_defaults` in `lib/codex.sh`.

## Default settings

In the user file `~/.codex/config.toml`:

```toml
[desktop]
notifications-turn-mode = "off"
notifications-permissions-enabled = true
notifications-questions-enabled = true

[tui]
notifications = ["approval-requested"]
notification_condition = "unfocused"
```

In the app, the first setting matches **Settings → Notifications → end of answer → Never**.
The next two switches keep permission and question alerts.
In the terminal, only alerts of the `approval-requested` category are kept,
when the terminal does not have focus. Depending on the terminal version, this category is not guaranteed
to cover every question; keep requests visible in the session.

## Limit: an alert does not always mean a blocked session

Research checked on 6 September 2026, app 26.901.51231 and CLI 0.153.4.

- The native settings offer no filter for "only when really waiting for the user",
  no configurable delay to check that a request is still open, and no notification quota.
- Automatic review can handle a permission request without waiting for a person.
  The notification category cannot select only the requests that still block.
- Some questions are asynchronous: the user can answer while Codex keeps working.
- `notify` is an external end-of-answer mechanism. It can also serve a Computer Use
  integration; Treelab neither removes nor replaces it. An existing program can therefore still
  raise alerts despite these settings.
- Codex hooks provide no `Notification` event and no documented way to
  filter app notifications after automatic review. `PermissionRequest` takes part
  in the decision to allow an action; it does not hide an alert that became useless.

Turning off all permission alerts would also hide the real requests for agreement. Treelab keeps
them, without changing `approval_policy`, `approvals_reviewer`, the protections or the macOS settings.
It does not change the app's internal files and adds no monitoring of conversations.

## Existing configuration and rollback

Ordinary `[desktop]` and `[tui]` tables, their quoted names, comments, multi-line
values and nested arrays are supported. LF and CRLF line endings are recognised.
Other settings and their comments are kept.
A symbolically linked configuration, target tables defined inline or by dotted keys,
or escaped names are left untouched, with a message pointing to this document. In that case,
adjust the values from the Codex settings or merge the block above into the existing notation,
without defining the same tables a second time.

After a change, the previous copy is in
`state/backups/install-<date>/codex-config.toml`. Putting it back in place of the user file
undoes the addition; first keep any other change made since the installation.
Running the installation again without change adds no duplicate and does not rewrite the file.

## Sources and checks

- [Notifications: app categories](https://learn.chatgpt.com/docs/notifications).
- [Configuration: terminal and external program](https://learn.chatgpt.com/docs/config-file/config-advanced#notifications).
- [Automatic review of approvals](https://learn.chatgpt.com/docs/sandboxing/auto-review).
- [Hooks and PermissionRequest](https://learn.chatgpt.com/docs/hooks#permissionrequest).
- Reading the code shipped with the app: three native preferences (`off`, `unfocused`, `always`
  for end of answer; booleans for permissions and questions), and notifications of asynchronous questions.

The automated tests prove the configuration produced, the backups and that choices are kept.
They do not prove that a future Codex version will never notify a non-blocking request.
