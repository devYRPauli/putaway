# Putaway

Putaway files the contents of a folder into the folders you already have.

Point it at Downloads. It reads each file, picks one of your folders, and shows you the plan. Files it is sure about are ready to move. For the rest, it suggests a folder and you decide. Nothing moves until you click Move, and Undo puts everything back.

## Install

```sh
brew install --cask devyrpauli/tap/putaway
```

Or download `Putaway.zip` from [Releases](https://github.com/devYRPauli/putaway/releases), unzip it, and drag Putaway to Applications.

Putaway needs macOS 26 or later.

## Use

1. Open Putaway. It shows a tray icon in the menu bar.
2. Add a SubQ API key. You can get one at [console.subq.ai](https://console.subq.ai).
3. Click **Tidy Downloads**. Check the plan, then click **Move**.

To tidy a different folder, click its name at the top of the window. To choose where files can go, click the folder name after "into folders in". Each subfolder of that folder is one choice.

In Finder, you can also right-click any folder and choose **Services > Tidy with Putaway**.

## What leaves your Mac

Putaway sends the first 1,000 characters of each file's text to SubQ. It does not send whole files. For scans and images, Putaway reads the text on your Mac first and sends only that text. For a file with no text, such as a zip, Putaway sends only the file name, and you confirm the folder.

Putaway never reads files with names like `.env`, `id_rsa`, `*.pem`, `passwords.csv`, or `recovery-codes.txt`. It leaves them in place.

Without a SubQ key, Putaway uses the Apple Intelligence model on your Mac. Then nothing leaves your Mac, and Putaway only suggests folders. You confirm each file.

## Safety

- Putaway never overwrites a file. If a folder already has `report.pdf`, the new file becomes `report 2.pdf`.
- Putaway skips a file that changed after the plan was made.
- Putaway skips downloads that are not complete.
- Undo puts back the last batch. It keeps a file in its new place if you changed the file after the move.

## Command line

The app includes a `putaway` command:

```sh
ln -s /Applications/Putaway.app/Contents/Helpers/putaway /usr/local/bin/putaway
putaway plan ~/Downloads --into ~/Documents
putaway apply
putaway undo
```

`putaway plan` moves nothing. `putaway apply` moves the files marked MOVE in the last plan. `putaway key` reads a SubQ key from standard input and stores it in the Keychain. The `SUBQ_API_KEY` environment variable overrides the stored key.

## Build from source

```sh
git clone https://github.com/devYRPauli/putaway
cd putaway
swift test
Scripts/package_app.sh
open build/Putaway.app
```

This needs Xcode 26 or later.

## License

MIT
