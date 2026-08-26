# GUI Session Interactions

## Images

The entire window accepts local PNG, JPEG, GIF, and WebP files through drag and drop. The composer installs the same handler so its native text field cannot convert a dropped file into path text. Pending images render as small removable rounded-square thumbnails directly above the prompt bar. Duplicate paths are ignored.

Sending captures the pending image list, clears the strip, and includes each image in the ACP prompt. Sent images remain visible as rounded thumbnails beneath the user message. The local GUI and ACP server use `_meta.afx.path` to preserve the absolute source path while the standard block retains `type`, `data`, and `mimeType`. afx validates the file and media type, captures a verified session-lifetime snapshot, and passes the resulting core image attachment to the model.

An image-only prompt is valid and lazily creates a session under the same startup invariant as text prompts.

## Active session tab

The active session's left-edge tab stays fully expanded and keeps its vertical title visible. Inactive tabs remain shallow until hovered. Every tab still shrinks proportionally near the window's safe top and bottom scrolling boundaries.

## New session directory

`/new` fades the main panel into a full-area New Session surface. It shows the current workspace and offers two actions:

- Use This Folder
- Choose Folder…

Choose Folder uses the native macOS directory picker. Selecting a different folder reconnects the ACP process with that directory as its workspace, refreshes commands, models, and workspace sessions, and returns to startup state. It does not create a session. The first prompt creates the session in the selected directory.
