# Voqora for Chrome and Edge

A small browser extension that sends text from web pages to the Voqora app on
your Mac. Voqora reads it aloud with your current voice. It works in Google
Chrome, Microsoft Edge, and other Chromium browsers (version 116 or later).

## What it does

- **Read selection.** Select text, then right-click and choose **Read selection
  with Voqora**, press `Option + Shift + R`, or choose **Read Selection** in the
  toolbar popup.
- **Read page.** Right-click an empty part of the page and choose **Read this
  page with Voqora**, or choose **Read Page** in the popup. The extension finds
  the main article text and leaves out menus, sidebars, footers, and scripts.
- **Stop.** Press `Option + Shift + S` or choose **Stop** in the popup.

Voqora reads up to 50,000 characters per request. A longer page or selection
is split into parts at paragraph or sentence breaks. The extension sends every
part at once, and Voqora reads them in order without a pause for you to
continue. **Stop** ends the reading and drops the parts still waiting.

You can change the shortcuts at `chrome://extensions/shortcuts` (in Edge,
`edge://extensions/shortcuts`), or from the **Shortcuts** link in the popup.

## Install

1. In Voqora, open **Settings -> Integrations** and turn on **Local API**.
   Note the port (51851 unless you changed it) and copy the API key.
2. Open `chrome://extensions` (in Edge, `edge://extensions`).
3. Turn on **Developer mode**.
4. Choose **Load unpacked** and pick this `extensions/chromium` folder.
5. The options page opens. Enter the port, paste the API key, and choose
   **Test Connection**. When it says it's connected, the settings are saved.
6. Pin the Voqora button to the toolbar if you want the popup handy.

To update, pull the latest code and choose the reload button on the extension's
card in `chrome://extensions`.

## Troubleshooting

| Message | What to do |
| --- | --- |
| Can't reach Voqora on port ... | Open Voqora, turn on Local API in Settings -> Integrations, and check that the port in the options matches. |
| Voqora didn't accept the API key | Copy the key again from Settings -> Integrations. Regenerating the key in Voqora makes the old one stop working. |
| The app isn't listening | Voqora's speech service is running but the app window is not connected to it. Quit and reopen Voqora. |
| Voqora is busy | Too many requests in a short time. Wait a moment and try again. |
| Your browser doesn't let extensions read this page | Browser pages such as `chrome://` pages, the Chrome Web Store, and the built-in PDF viewer are off limits to extensions. Select text and use the right-click menu where it is offered, or open a regular web page. |

## Privacy

- Nothing leaves your Mac. The extension talks only to `http://127.0.0.1`, the
  Voqora local API on this computer. It has no analytics and makes no other
  network requests.
- It reads a page only when you ask: through the right-click menu, the popup,
  or a shortcut. It uses the `activeTab` permission for this, so it has no
  standing access to any site.
- The port and API key are kept in the browser's extension storage on this
  computer (`chrome.storage.local`). Remove the extension to delete them.
- The last error shown in the popup is kept in the browser's session storage
  and is cleared when the browser quits.

Permissions it asks for: `activeTab`, `contextMenus`, `storage`, `scripting`,
and access to `http://127.0.0.1/*`.

## Development

The extension is plain JavaScript with no build step and no dependencies. The
logic that does not need a browser (text extraction scoring, chunking, error
messages, settings, URL building) lives in `src/` and is tested with Node's
built-in test runner:

```sh
cd extensions/chromium
npm test
```

`npm test` runs `node --test test/*.test.js` and needs Node 20 or later.
