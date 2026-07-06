# LINUX DO Research Audit Template

Use this template internally while reading LINUX DO content. It prevents overclaiming and makes final reporting precise.

## Scope

```text
User request:
Target tab/title:
Target URL(s):
Scope requested:
  [ ] network search/readers first
  [ ] bookmarks page
  [ ] specific topic
  [ ] all visible floors
  [ ] all replies/floors
  [ ] linked tutorials
  [ ] attachments/downloads
  [ ] derived deliverable
Out of scope or deferred:
```

## Network Pass

```text
Queries used:
Proxy used:
Direct URLs tried:
Reader URLs tried:
Topic-position URLs tried:
Network JSON tried:
Network coverage:
Network gaps requiring browser fallback:
```

Do not treat search snippets as proof. Record original topic text or mark the claim unresolved.

## Browser Tabs

```text
Initial open tabs:
id | title | url | ownership

Claimed existing tabs:
id | title | url | reason

Temporary tabs created:
id | purpose | requested_url | final_url | final_title | closed | evidence

Final open tabs:
id | title | url | retained_reason
```

Ownership values:

- `user-owned`
- `task-created`
- `ambiguous`

Only close `task-created` tabs with matching URL/title evidence.

Do not navigate browser/plugin tabs to LINUX DO topic `.json` URLs. If browser fallback is required, use normal topic pages and topic-position URLs.

## Bookmark Coverage

```text
Bookmarks source URL:
Extraction method:
Total visible bookmarks:

bookmark_index | title | url | category/tags | excerpt | selected? | reason | status
```

Status values:

- `read`
- `skipped-out-of-scope`
- `deferred`
- `failed`

Never skip old bookmarks merely because they look old unless the user authorized filtering.

## Topic Coverage

```text
Topic URL:
Title:
Expected posts/highest floor:
Extraction methods tried:
  [ ] topic JSON
  [ ] current DOM
  [ ] temporary /floor tab
  [ ] other

Floors read:
Missing floors:
Gaps closed by:
Remaining gaps:
```

Floor table:

```text
floor | author | extracted_from | text_summary | links | attachments | warnings | actionability
```

Actionability values:

- `instruction`
- `warning`
- `attachment`
- `tutorial`
- `question`
- `noise/thanks`

## Link Coverage

```text
source_floor | link_text | url | action | result | temp_tab_id | tab_closed
```

Action values:

- `opened-read`
- `downloaded`
- `resolved-cdn`
- `skipped-profile`
- `skipped-navigation`
- `deferred`
- `failed`

## Attachment Coverage

```text
source_floor | visible_name | visible_size | forum_url | resolved_url | local_path | bytes | inspected | notes
```

Inspection summary:

```text
archive_path:
entry_count:
json_entry_count:
format:
top_level_keys:
credential_keys:
missing_required_fields:
secret_values_printed: no
```

## Findings

Separate conclusions by confidence:

```text
Verified facts:
- ...

Inferences:
- ...

Warnings from source:
- ...

Unresolved:
- ...
```

## Final Report Checklist

Before answering:

- [ ] network methods and proxy/direct path are reported;
- [ ] no temporary tabs remain open;
- [ ] user-owned tabs were not closed;
- [ ] downloads are listed with absolute paths;
- [ ] generated files are listed with absolute paths;
- [ ] coverage is stated exactly;
- [ ] unread links/floors/bookmarks are disclosed;
- [ ] no cookies/localStorage/sessionStorage were extracted;
- [ ] no forum mutation was performed;
- [ ] cleanup actions are reported with evidence;
- [ ] if subagents were used, their audit summaries are integrated.
