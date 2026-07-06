# LINUX DO Attachments And Linked Resources

Use this reference when a LINUX DO topic includes upload links, zip files, images, tutorials, GitHub releases, or other linked resources.

## Attachment Discovery

During the network-first pass, try public reader/direct download methods before browser fallback. Use browser fallback only when a relevant attachment/link cannot be resolved with enough evidence through network methods.

Extract links from relevant posts:

- `a[href]` text and URL;
- visible filename;
- visible size, for example `195.2 KB`;
- source floor number;
- surrounding warning text.

Prioritize:

- `.zip`, `.json`, `.txt`, `.yaml`, `.md`;
- tutorial/source topic links;
- GitHub release links;
- links explicitly introduced as "教程", "配置", "来源", "密码", "上一个帖子", "删除不可用账号".

Ignore or deprioritize:

- user profile links;
- avatar/images unless the image contains instructions;
- category navigation;
- repeated reaction/thanks links.

## Cloudflare And Short URLs

Direct shell requests to `https://linux.do/...` can return `403 Forbidden`.

Do not interpret that as the attachment being unavailable. Use Edge to resolve the forum short URL because the logged-in browser session may be needed for the redirect.

When using Edge/browser fallback, do not open topic `.json` URLs to find attachments. Open the normal topic or topic-position page and extract visible links from the DOM.

Typical flow:

1. Open a temporary Edge tab to the forum upload short URL.
2. Let it redirect or fail as a download navigation.
3. Capture the final CDN URL if visible, for example `https://cdn3.ldstatic.com/original/...zip`.
4. Close the temporary tab.
5. If the final CDN URL does not require cookies, download it with a normal HTTP client.
6. Verify the downloaded file size against the topic's visible size.

Do not extract cookies to make curl work.

## Download Handling

Before downloading:

- check whether the file already exists;
- avoid overwriting unrelated user files;
- choose a clear output path;
- record whether the download came from Edge resolution or direct URL.

After downloading:

- record absolute path;
- record byte size and timestamp;
- inspect archive structure if it is a zip;
- inspect JSON keys and counts without printing secrets;
- keep the file unless the user asks to clean it or it is clearly a temporary artifact created only for internal processing.

Do not delete downloads by broad pattern. Cleanup must follow the user's cleanup safety rules.

## Archive Inspection

Use structured zip APIs, not ad hoc byte/string scans.

For each zip, report:

- number of entries;
- number of JSON entries;
- sample entry name;
- top-level keys of sample JSON;
- whether tokens are present as booleans, not values;
- whether it is a bundle or single-account collection.

Secret-safe sample output:

```text
JsonEntries: 100
TopKeys: access_token,account_id,email,expired,id_token,last_refresh,refresh_token,type
HasAccessToken: true
HasRefreshToken: false
```

## Linked Tutorial Handling

When a linked tutorial is relevant:

1. Open one temporary tab.
2. Extract main post and high-signal links.
3. Summarize the actionable steps.
4. Record what the tutorial does and does not apply to.
5. Close the temporary tab.

Example distinction:

- A CPA tutorial may explain running CliProxyAPI locally.
- That does not mean a Sub2API server plan must deploy CPA.
- State the relationship explicitly.

## Link Coverage Report

For each important link, track:

```text
source_floor | link_text | url | action | result | tab_status
```

Possible actions:

- read topic;
- downloaded attachment;
- resolved CDN URL;
- skipped as profile/navigation;
- deferred because out of scope.

Final answers should mention skipped high-signal links if they remain unread.

## Safety Boundaries

Allowed:

- read public/visible forum content through Edge;
- resolve attachment redirects;
- download attachments needed for the user's task;
- inspect local downloaded files;
- create derived summaries or import kits.

Not allowed without explicit authorization:

- posting replies;
- liking/bookmarking/unbookmarking;
- uploading files;
- reading browser cookie stores;
- extracting localStorage/sessionStorage tokens;
- mass downloading unrelated bookmarks;
- deleting user downloads.
