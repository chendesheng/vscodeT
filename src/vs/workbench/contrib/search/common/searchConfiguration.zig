// Port of the default values registered by
// `src/vs/workbench/contrib/search/browser/search.common.contribution.ts` and
// `search.contribution.ts`.
//
// The terminal configuration registry takes JSON default fragments. The
// workbench composition root registers this fragment together with the
// generic terminal defaults so the search view can read the same keys as
// upstream. Language-override, policy and remote scopes are not ported.

pub const defaults_json =
    \\{
    \\  "search": {
    \\    "exclude": {
    \\      "**/node_modules": true,
    \\      "**/bower_components": true,
    \\      "**/*.code-search": true
    \\    },
    \\    "useIgnoreFiles": true,
    \\    "smartCase": false,
    \\    "maxResults": 20000,
    \\    "sortOrder": "default",
    \\    "searchOnType": true,
    \\    "searchOnTypeDebouncePeriod": 300,
    \\    "showLineNumbers": false,
    \\    "collapseResults": "alwaysExpand",
    \\    "defaultViewMode": "list",
    \\    "seedOnFocus": false,
    \\    "seedWithNearestWord": false,
    \\    "useReplacePreview": true
    \\  }
    \\}
;
