# Build the English IPA Without a Mac

This source is based on Location Spoofer v1.0.5. The app interface, setup instructions, diagnostic messages, bundled proxy-module descriptions, permission prompts, and setup screenshots have been rewritten in English.

## Build on GitHub

1. Create a new GitHub repository, or fork `xweiba/location-spoofer`.
2. Upload this source tree to the repository. Make sure the hidden `.github` directory is included.
3. Open the repository's **Actions** tab. If GitHub asks, enable workflows for the repository.
4. In the workflow list, choose **Build English Unsigned IPA**.
5. Select **Run workflow**. Leave **Run iOS Simulator tests after building** enabled for the first build.
6. Wait for the **Build English IPA** job to finish successfully.
7. Open the completed workflow run. Under **Artifacts**, download **Location-Spoofer-English-unsigned**.
8. Unzip the downloaded artifact. It contains `Location-Spoofer-English-unsigned.ipa`.
9. Sign that IPA with your developer certificate and provisioning profile using your usual signing tool, then install the signed IPA on the iPhone.

The GitHub artifact is unsigned. No Apple certificate, provisioning profile, or signing secret is required in GitHub Actions.

## App Mode Reminder

App Mode uses a local proxy at `127.0.0.1:8888` and therefore requires Wi-Fi. Follow the English first-run guide to configure the Wi-Fi proxy, install the `Location Spoofer CA` profile, and enable full trust for that certificate.
