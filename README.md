# Putaway

Putaway files the contents of a folder into the folders you already have.

Point it at Downloads. It reads each file, picks one of your folders, and shows you the plan. Files it is sure about are ready to move. For the rest, it suggests a folder and you decide. Nothing moves until you click Move, and Undo puts everything back.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/devYRPauli/putaway/main/install.sh | bash
```

This puts Putaway in `~/Applications` and opens it. Or use Homebrew:

```sh
brew install devyrpauli/tap/putaway
```

Putaway needs a Mac with Apple silicon and macOS 26 or later.

## Use

1. Open Putaway. It shows a tray icon in the menu bar.
2. Click **Tidy Downloads**. Check the plan, then click **Move**.

To change how Putaway picks folders, click **Change engine**. You have four choices:

- **Apple Intelligence**: the default. It runs on your Mac and needs Apple Intelligence turned on. It suggests a folder for each file, and you confirm each one.
- **SubQ Snap**: needs a SubQ API key from [console.subq.ai](https://console.subq.ai). It is the most accurate engine, and files it is sure about are ready to move.
- **Jev**: needs a TypeSafe API key for Jev. It works the same way as SubQ.
- **Your own model**: any server with the OpenAI chat API, such as Ollama, LM Studio, llama.cpp, or mlx_lm. Enter its address, such as `http://localhost:11434/v1`, and the model name. It suggests a folder for each file, and you confirm each one.

To tidy a different folder, click its name at the top of the window. To choose where files can go, click the folder name after "into folders in". Each subfolder of that folder is one choice.

In Finder, you can also right-click any folder and choose **Services > Tidy with Putaway**.

## What leaves your Mac

With SubQ or Jev, Putaway sends your folder names and the first 1,000 characters of each file's text to that service. It does not send whole files. For scans and images, Putaway reads the text on your Mac first and sends only that text. For a file with no text, such as a zip, Putaway sends only the file name, and you confirm the folder.

Putaway never reads files with names like `.env`, `id_rsa`, `*.pem`, `passwords.csv`, or `recovery-codes.txt`. It leaves them in place. If a file's text looks like a private key or an API token, Putaway does not send it.

With Apple Intelligence, nothing leaves your Mac. With your own model, the same text goes only to the server you entered.

## Safety

- Putaway never overwrites a file. If a folder already has `report.pdf`, the new file becomes `report 2.pdf`.
- Putaway skips a file that changed after the plan was made.
- Putaway skips downloads that are not complete.
- Undo puts back the last batch. It keeps a file in its new place if you changed the file after the move.

## Command line

Both install methods add a `putaway` command:

```sh
putaway plan ~/Downloads --into ~/Documents
putaway apply
putaway undo
```

`putaway plan` moves nothing. `putaway apply` moves the files marked MOVE in the last plan.

The app and the command use the same engine. To set it from the command line:

```sh
putaway engine apple
putaway engine subq
putaway engine jev
putaway engine own http://localhost:11434/v1 qwen2.5:7b-instruct
```

`putaway key subq` and `putaway key jev` read a key from standard input and store it in the Keychain. The `SUBQ_API_KEY` and `TYPESAFE_API_KEY` environment variables override the stored keys. If you set no engine, Putaway uses a SubQ key, then a Jev key, then Apple Intelligence.

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
