# Gmail Desktop for macOS

An independent Mac app for using Gmail with separate sessions for multiple Google accounts. It displays the real Gmail website and adds an account switcher, Dock unread badge, notifications, keyboard shortcuts, `mailto:` support, and attachment handling.

**This is an independent project, not an official Google app.** Google can change Gmail or its sign-in rules at any time. Some accounts may be unable to sign in from an embedded browser.

[Инструкция на русском ↓](#установка-по-русски)

## Download and install

Requirements: a Mac with **macOS 14 Sonoma or newer** (Apple silicon or Intel).

> [!IMPORTANT]
> **macOS will warn you the first time you open the app. This is expected.**
>
> Apple only lets apps open without a warning if the developer pays for an Apple Developer account ($99/year) and sends each version to Apple for an automated check ("notarization"). Gmail Desktop is a free hobby project, so it isn't registered with Apple. macOS therefore says it "can't verify" the app. That does **not** mean a virus was found; macOS simply has no information about the app.
>
> The full source code is public in this repository, and every release is built automatically by GitHub from that code. You only need to allow the app once (steps 4–5 below).

1. Open this repository's **Releases** page (link on the right side of the page) and download `Gmail Desktop.zip` from the latest release.
2. Double-click the ZIP. Drag `Gmail Desktop.app` into your **Applications** folder.
3. Open **Gmail Desktop** from Applications.
4. The first time, macOS will probably say it can't verify the app. This is expected: the app is free and not registered with Apple. Click **Done** (not "Move to Trash").
5. Open **System Settings → Privacy & Security**, scroll down to the message about "Gmail Desktop", click **Open Anyway**, and confirm with your Mac password or Touch ID.
6. Sign in on Google's page. From then on the app opens normally.

Only do steps 4–5 for a ZIP you downloaded from this project's Releases page.

If the Releases page is empty, there is no downloadable version yet.

## What it does

- Separate local web sessions for each account, with an account switcher and unread counts.
- Dock badge and macOS notifications; Gmail's own notification setting controls detailed banners.
- `mailto:` links, optional compose window, file attachments and downloads to `~/Downloads`.
- Keyboard shortcuts for composing, switching accounts, reloading and navigating Gmail.

## Privacy and security

- The app runs inside the macOS App Sandbox and uses Apple's WebKit (the engine behind Safari).
- Each account has its own separate storage; signing out of an account in the app deletes its cookies and cache.
- The app only shows Google's own pages. Your password is entered only on Google's sign-in page.
- Besides the Gmail website itself, the app's only network request is Gmail's unread-count feed, sent to Google for accounts that are not currently open.
- No analytics, no tracking, no servers of its own.

## Build from source

Requirements: macOS 14+, Xcode or the Xcode Command Line Tools.

```sh
git clone <repository-url>
cd GmailDesktop
./build-app.sh
open "build/Gmail Desktop.app"
```

This also creates `Gmail Desktop.zip`. `./build-app.sh --install` replaces `/Applications/Gmail Desktop.app`. `swift build` alone does not assemble the `.app` bundle needed for notifications, `mailto:` and sandbox entitlements.

Releases are built automatically by GitHub Actions when a version tag such as `v1.0.0` is pushed (it must match `CFBundleShortVersionString` in `Resources/Info.plist`).

The `electron/` folder contains an experimental Chromium-based alternative. It is not part of the releases; see `electron/package.json` for its scripts.

## Установка по-русски

Нужен Mac с **macOS 14 Sonoma или новее** (любой: Apple silicon или Intel).

> [!IMPORTANT]
> **При первом запуске macOS покажет предупреждение. Это нормально.**
>
> Apple пропускает приложения без предупреждения, только если разработчик платит за аккаунт Apple Developer ($99 в год) и отправляет каждую версию на автоматическую проверку («нотаризацию»). Gmail Desktop — бесплатный некоммерческий проект и не зарегистрирован в Apple, поэтому macOS пишет, что «не может проверить» приложение. Это **не** значит, что найден вирус: у macOS просто нет сведений об этом приложении.
>
> Весь исходный код открыт в этом репозитории, а каждую версию автоматически собирает GitHub из этого кода. Разрешить запуск нужно один раз (шаги 4–5 ниже).

1. Откройте страницу **Releases** этого репозитория (ссылка справа на странице) и скачайте `Gmail Desktop.zip` из последней версии.
2. Дважды щёлкните по ZIP-файлу и перетащите `Gmail Desktop.app` в папку **Программы** (Applications).
3. Откройте **Gmail Desktop** из папки «Программы».
4. В первый раз macOS скорее всего скажет, что не может проверить приложение. Это нормально: приложение бесплатное и не зарегистрировано в Apple. Нажмите **Готово** (не «Переместить в Корзину»).
5. Откройте **Системные настройки → Конфиденциальность и безопасность**, прокрутите вниз до сообщения про «Gmail Desktop», нажмите **Всё равно открыть** и подтвердите паролем от Mac или Touch ID.
6. Войдите в аккаунт Google на странице Google. Дальше приложение будет открываться как обычно.

Делайте шаги 4–5 только для файла, скачанного со страницы Releases этого проекта.

## Author

Made by **Ivan Zakharov** · [LinkedIn](https://www.linkedin.com/in/ivan-zakharov-craftio-design/)

## License

The source code is available under the [MIT License](LICENSE). Google and Gmail are trademarks of Google LLC; this project is not affiliated with or endorsed by Google.
