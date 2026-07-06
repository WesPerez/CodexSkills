# Discourse Topic And Floor Extraction

LINUX DO is Discourse-based. Use this reference when reading topics, replies, floors, bookmarks, and activity pages.

## Coverage Standard

Do not claim "all floors" or "all replies" unless you have:

- topic URL and title;
- expected post count or highest visible floor when available;
- list of floor numbers extracted;
- explicit handling of missing/cloaked floors;
- linked topics/tutorials followed when relevant;
- final gap list is empty or clearly reported.

If the user asks "did you read every post?", answer with exact coverage, not confidence language.

## Network JSON Only

During the network-first pass, shell/network requests may try Discourse JSON when it is reachable without browser credentials:

- topic URL: `https://linux.do/t/topic/2527525`
- JSON URL: `https://linux.do/t/topic/2527525.json`

The JSON may contain:

- `title`
- `posts_count`
- `highest_post_number`
- `post_stream.posts`
- `post_stream.stream`

Cloudflare can block direct shell requests. If network JSON access fails, use reader pages or escalate to browser DOM extraction.

Do not navigate browser/plugin tabs to `.json` topic URLs. Browser visits to `https://linux.do/t/topic/<id>.json` are commonly blocked by Cloudflare and waste time. In the browser fallback, use normal topic pages and topic-position URLs such as `/7`, `/14`, and `/30`, then extract DOM-visible floors.

Never bypass by stealing cookies from the browser.

## DOM Extraction Pattern

Inside `tab.playwright.evaluate`, extract bounded, structured content:

```js
var posts = await tab.playwright.evaluate(() => {
  const strip = (html) => String(html || "")
    .replace(/<style[\s\S]*?<\/style>/g, " ")
    .replace(/<script[\s\S]*?<\/script>/g, " ")
    .replace(/<[^>]+>/g, " ")
    .replace(/\s+/g, " ")
    .trim();

  return Array.from(document.querySelectorAll(
    ".topic-post[data-post-number], article[id^='post_'], [id^='post_']"
  )).map((el) => {
    const num = Number(
      el.getAttribute("data-post-number") ||
      (el.id || "").match(/post_(\d+)/)?.[1] ||
      0
    );
    const links = Array.from(el.querySelectorAll("a[href]")).slice(0, 80)
      .map((a) => ({ text: strip(a.innerHTML || a.textContent).slice(0, 160), href: a.href }));
    return {
      tag: el.tagName,
      id: el.id,
      className: el.className,
      post_number: num,
      text: strip(el.innerHTML || el.textContent).slice(0, 5000),
      links
    };
  }).filter((p) => p.post_number && p.text);
});
```

Deduplicate wrapper divs and inner articles by floor. Prefer the `ARTICLE` version when present. Ignore pure cloaked placeholder text such as `由 username 于 ... 发布` when it has no body.

## Cloaked Or Lazy Floors

Discourse often renders distant floors as placeholders:

```html
<div class="post-stream--cloaked" data-post-number="6" id="post_6">
```

This does not mean the reply has no content. It means the floor is not loaded.

To load missing floors:

1. Determine missing floor range.
2. Open one temporary topic-position tab:
   - `/7` to read around floors 6-8;
   - `/10` to read around floors 9-15;
   - choose a center floor near the missing range.
3. Wait briefly for content.
4. Extract only the needed range.
5. Close the temporary tab and verify closure.

Example temporary URL:

```text
https://linux.do/t/topic/2527525/7
```

Do not leave these temporary tabs open.

## Bookmark/Activity Pages

For bookmark pages such as:

```text
https://linux.do/u/<username>/activity/bookmarks
```

Use the existing Edge tab if already open. Extract bookmark cards/rows with:

- visible title;
- URL;
- category;
- excerpt;
- last activity;
- any tags or metadata visible.

Then process each relevant bookmark topic with the topic workflow. If there are many bookmarks and the user wants all of them, keep a progress table:

```text
topic_url | title | status | floors_read | links_followed | attachments | notes
```

Do not silently skip "old" bookmarks unless the user authorized filtering.

## Linked Topics And Tutorials

Follow links when they plausibly contain:

- original source package;
- tutorial/use instructions;
- password or warning;
- upstream account-generation method;
- deletion/cleanup guidance;
- reply context required to interpret the current post.

Do not follow unrelated social/profile/category links unless needed.

For each followed link, record:

- source floor;
- link text;
- URL;
- whether opened;
- key extracted facts;
- whether temporary tab closed.

## Floor Summary Format

For a small topic, summarize every floor:

```text
1: author - attachments, links, main instructions/warnings.
2: author - short reaction/no new info.
3: author - asks about source group/no action.
...
```

For a large topic, separate:

- actionable instructions;
- warnings/risk reports;
- attachments;
- tutorials/links;
- repeated thanks/noise;
- unanswered questions.

Still keep coverage records even if the final answer is concise.

## Accuracy Checks

Before concluding:

- compare extracted floors to expected `posts_count`/highest floor if known;
- revisit any missing floor range;
- inspect links in the main post and high-signal replies;
- verify downloaded attachment sizes against visible forum sizes when possible;
- state any limits, such as "read visible 1-15 floors; did not read older bookmarked topics".

## Common Pitfalls

- Reading page 1 only and claiming all replies.
- Treating cloaked placeholders as empty replies.
- Opening duplicate tabs for the same URL.
- Closing the user's original tab.
- Losing track of temporary download/position tabs.
- Using direct shell HTTP and treating Cloudflare 403 as proof the resource is inaccessible.
- Navigating browser/plugin tabs to topic `.json` URLs instead of using normal topic pages and DOM extraction.
- Printing too much page text instead of extracting structured data.
