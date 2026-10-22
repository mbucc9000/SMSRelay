<img src="icon.png" width="80" align="right" alt="">

# SMS Relay

Get the 2FA and login codes texted to your main iPhone on a second iOS 6 iPhone: a Shortcuts automation relays them over iMessage, and they show from the real sender.

## Features

- A Shortcuts automation on your main iPhone forwards only code texts, over iMessage, to your own number.
- SMS Relay rewrites that notification to show the real sender and the text.
- The code goes straight to the clipboard.
- If the same code also arrives as an iMessage, the second copy is hidden.

## How to use

1. Set up the Shortcuts automation on your main iPhone (Main iPhone setup, below).
2. Codes then arrive on this iPhone as notifications from the real sender, with the code on the clipboard.
3. Settings › SMS Relay turns copying or duplicate hiding off.

## Requirements

- Jailbroken iOS 6 (tested on an iPhone 5 with iOS 6.1.2)
- Cydia Substrate and PreferenceLoader (Cydia installs them for you)
- A main iPhone with Shortcuts automations, signed in to iMessage
- This iPhone signed in to iMessage with the same Apple ID

## Install

In Cydia, add `https://mbucc9000.github.io/slopkit/` and install **SMS Relay**. Or download the `.deb` from [Releases](../../releases) and install it with `dpkg -i`.

## Main iPhone setup

1. Shortcuts → Automation → New → **Message**. Message Contains: a single space. Run Immediately, Notify off.
2. Add **Match Text** on the message's Content, with this pattern:

```
(?is)^(?!\s*\[SMS\])(?=.*(\b(code|passcode|pin|otp|2fa|mfa)\b|verif|one[- ]?time|log ?in|sign[- ]?in|two[- ]factor|two[- ]step|authenticat))(?=.*(?<![\d$.,:/])(?<!\d-)(\d{4,8}|\d{3}[- ]\d{3})(?![\d]|[.,:/-]\d)).*
```

3. Add **If** Matches has any value → **Send Message** to your own number: `[SMS] `, the Sender, a line break, then the Content.
4. Mute your own-number chat on the main iPhone.

## Building

[Theos](https://theos.dev) with the iOS 6.1 SDK: `make package FINALPACKAGE=1`.

## License

MIT.
