# OpenVacuum Privacy Policy

Effective November 7, 2026

OpenVacuum is an iPhone app for robot vacuums running Valetudo. It is developed by Siddhartha Bariker and is not affiliated with the Valetudo project.

## The short version

OpenVacuum doesn't collect, store on a server, sell or share any data about you. There are no accounts, no analytics, no advertising and no tracking. The developer can't see anything you do in the app.

## Who the app talks to

The app connects only to the robots you add, directly over your local network. It has no server of its own and uses no third-party services or SDKs. To find robots, it asks for Local Network access and looks for Valetudo robots on your network.

Links to the Valetudo website or to GitHub open in Safari. Those sites have their own privacy policies.

## What stays on your iPhone

- **Robot passwords** are stored in the iOS Keychain.
- **Saved robots** (name, address and username) are stored in the app's settings on your iPhone.
- **Wi-Fi details** you enter while setting up a new robot are sent only to that robot.
- **Map exports** are created only when you choose to share or save one, using the share sheet.

Deleting the app removes its settings. You can also remove a saved robot in Settings, which deletes its stored password.

## Camera and obstacle photos

If you have turned on camera streaming on your robot yourself, the app can show the live video. The app can't turn the camera on. Video is decoded and shown on your iPhone. It is never recorded, saved or sent anywhere. If you turn on Identify What's in View, the app checks a frame every few seconds with Apple's Vision framework on your iPhone to name what the camera sees.

Obstacle photos are downloaded from your robot so you can see them. When you open one, the app checks it with Apple's Vision framework on your iPhone to name the object and to notice people or pets in it. Photos are kept in memory only, are not saved on your iPhone, and are never uploaded.

## Security

Valetudo doesn't support HTTPS, so traffic between the app and your robot, including the robot login and Wi-Fi passwords during setup, is not encrypted on your local network. Use a robot password you don't use anywhere else.

## Children

The app is not directed at children and collects no data from anyone.

## Changes

Any changes to this policy will be published in this file, with a new effective date.

## Contact

Open an issue at https://github.com/bsidio/valetudo-ios/issues
