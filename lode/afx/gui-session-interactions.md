# GUI Session Interactions

## Images

The entire window accepts local PNG, JPEG, GIF, and WebP files through drag and drop. The composer installs the same handler so its native text field cannot convert a dropped file into path text. Pending images render as small removable rounded-square thumbnails directly above the prompt bar. Duplicate paths are ignored.

Sending captures the pending image list, clears the strip, and includes each image in the ACP prompt. Sent images remain visible as rounded thumbnails above the user message text. The local GUI and ACP server use `_meta.afx.path` to preserve the absolute source path while the standard block retains `type`, `data`, and `mimeType`. afx validates the file and media type, captures a verified session-lifetime snapshot, and passes the resulting core image attachment to the model. Session history updates include snapshot paths and media types so thumbnails survive application restarts.

An image-only prompt is valid and lazily creates a session under the same startup invariant as text prompts.

## Active session tab

The active session's left-edge tab stays fully expanded and keeps its vertical title visible. Inactive tabs remain shallow until hovered. Every tab still shrinks proportionally near the window's safe top and bottom scrolling boundaries.

## Session loading

Selecting a tab updates active-tab state immediately. ACP history replay is buffered and applied in one main-actor update instead of triggering one render per chunk. Conversations already visited in the current application process are cached by session ID and appear immediately when revisited while afx refreshes the durable session in the background. A generation guard makes rapid clicks last-selection-wins.

The GUI stores the last non-empty session ID and reloads it after ACP startup when that session still exists in the current workspace. The main window uses an autosaved frame name; a missing saved frame falls back to the 670 × 880 default.

## New session directory

`/new` fades the main panel into a full-area New Session surface. It shows the current workspace and offers two actions:

- Use This Folder
- Choose Folder…

Choose Folder uses the native macOS directory picker. Selecting a different folder reconnects the ACP process with that directory as its workspace, refreshes commands, models, and workspace sessions, and returns to startup state. It does not create a session. The first prompt creates the session in the selected directory.

Command-T returns directly to startup state in the current workspace. Like `/new`, it does not create durable session state until the first prompt.

## Distribution

`scripts/build-app.sh` produces `dist/afx.app` from a Release SwiftPM build, installs `Packaging/Info.plist`, signs with `CODE_SIGN_IDENTITY` or an ad-hoc identity, and verifies the resulting bundle. Launch the bundle through LaunchServices so macOS supplies its bundle identity and scene lifecycle.
