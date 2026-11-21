// Port of the Activity Bar / layout defaults registered by
// `src/vs/workbench/browser/workbench.contribution.ts`
// (`LayoutSettings` in `services/layout/browser/layoutService.ts`).
//
// The terminal configuration registry takes JSON default fragments and the
// workbench composition root registers this one next to the search, terminal
// and theme defaults. Registering the keys is what lets the side bar part read
// them from workspace settings as well: unregistered keys fall back to the
// user scope in the configuration service. Policy, remote and language-override
// scopes are not ported.

pub const defaults_json =
    \\{
    \\  "workbench": {
    \\    "activityBar": {
    \\      "location": "default",
    \\      "autoHide": false,
    \\      "compact": false
    \\    }
    \\  }
    \\}
;
