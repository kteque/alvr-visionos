# Publishing AirFrameXR to TestFlight

**Who this is for:** the person who owns the Apple Developer account. You do not need to be a developer. Everything is
clicking in a web browser and pasting a few values. Plan about **45 minutes** the first time (most of it waiting for
Apple), and **2 minutes** for every later build.

**The whole job in three parts:**

1. **Apple** (websites): register the app, make an API key, note a few values. *Part 1.*
2. **GitHub** (website): make your own copy of the project and paste those values in. *Part 2.*
3. **Press one button**: the build is made, signed and sent to TestFlight for you. *Part 3.*

Original project (the link everything starts from): **https://github.com/jfbobier/alvr-visionos**

> **Golden rules, read once**
> - **Copy and paste, never retype.** A single wrong letter in a name or an ID is the number one cause of failure.
> - **Do the parts in order.** Part 2 needs the values you collect in Part 1.
> - **Write the values down as you go** in the worksheet below (a note on your phone or computer is fine).
> - **Never share the `.p8` file or post it anywhere** (chat, email, screenshots). It is a password for uploading apps
>   to your account. If you ever do, revoke it (explained in Part 1, step 3).
> - **If a page looks different from this guide**, look for the words in **bold**: Apple moves menus around a little.
> - **A red cross in Part 2 is not your fault** most of the time. Copy the page address and send it to whoever helps you.

## Your worksheet (fill it in as you go)

| # | Value | Example | Yours |
|---|---|---|---|
| 1 | **Bundle ID** | `io.github.airframexr.client` (use exactly this unless Apple refuses it, see Part 1 step 1) | |
| 2 | **Key ID** | `ABC123DEFG` (10 characters) | |
| 3 | **Issuer ID** | `69a6de80-1234-47e3-e053-5b8c7c11a4d1` (a long code with dashes) | |
| 4 | **The `.p8` file** | `AuthKey_ABC123DEFG.p8` | (the file itself) |
| 5 | **Team ID** | `Z9Y8X7W6V5` (10 characters) | |
| 6 | **Your GitHub user name** | `yourname` | |

---

# Part 1: Apple

Do this in a web browser, signed in with the Apple ID of the developer account. Use a computer, not the headset.
About 15 minutes.

### 0. Check the account is ready

1. Open **https://developer.apple.com/account** and sign in.
2. If a banner at the top says an agreement must be reviewed (**Review Agreement**), click it and **Agree**. Nothing
   works until you do.
3. The account must be a paid **Apple Developer Program** membership (99 USD a year). If the page offers **Join the
   Apple Developer Program** instead of your name and team, the membership is not active yet:
   https://developer.apple.com/programs/enroll/ (approval can take a day or two).
4. You must be the **Account Holder** or an **Admin**. Other roles cannot do the next steps.

### 1. Choose and register the bundle ID

The **bundle ID** is the app's unique name on Apple's side, like a web address written backwards. It cannot be changed
later, so use the recommended one:

> **`io.github.airframexr.client`**

Why this one: it is neutral (not tied to a person), it is the usual form for open projects without their own website,
and Apple never checks that you own a domain. Letters, digits, dots and hyphens only.

**If Apple says "not available"** (someone already used it), add a word: `io.github.airframexr.visionclient`. Then use
that new one *everywhere* below. Do not use spaces or capital letters.

1. Open **https://developer.apple.com/account/resources/identifiers/list**.
2. Click the blue **+** next to **Identifiers**.
3. Choose **App IDs**, click **Continue**, choose **App**, click **Continue**.
4. **Description**: `AirFrameXR`.
5. **Bundle ID**: tick **Explicit** and **paste** the bundle ID.
6. Leave every capability as it is. Click **Continue**, then **Register**.

*Check:* the new line appears in the Identifiers list with the bundle ID you pasted.

### 2. Create the app in App Store Connect

1. Open **https://appstoreconnect.apple.com/apps** and sign in (same Apple ID). If it asks you to accept terms, do so.
2. Click the **+** at the top left of the page, then **New App**.
3. Fill in the form:
   - **Platforms**: tick **visionOS** (only).
   - **Name**: `AirFrameXR`. It must be unique on the whole App Store: if Apple says it is taken, use `AirFrameXR
     Client`. (The name is only shown to testers and can be changed later.)
   - **Primary Language**: English (U.S.).
   - **Bundle ID**: open the list and pick the one you registered. **If the list is empty or does not show it**, step 1
     was not completed: go back and register it, then reload this page.
   - **SKU**: any text, for example `airframexr-client`. Nobody sees it.
   - **User Access**: **Full Access**.
4. Click **Create**.

You can leave every other page of the app empty. TestFlight does not need a description, screenshots or a price.

*Check:* **AirFrameXR** appears in your list of apps.

### 3. Create the API key (this lets GitHub upload for you)

This is the key that replaces your Apple ID and password. Apple IDs cannot be used here (they need a two-factor code
that a machine cannot type).

1. Open **https://appstoreconnect.apple.com/access/integrations/api**. (Or: top right your name > **Users and
   Access** > the **Integrations** tab > **App Store Connect API**.)
2. The very first time, the **Account Holder** must click **Request Access** and accept the terms. If you are only an
   Admin and the button is missing, ask the Account Holder to do this one click.
3. Click **Team Keys** (not "Individual Keys"), then the **+** (or **Generate API Key**).
4. **Name**: `GitHub TestFlight`. **Access**: **Admin** (a lower role makes signing fail later). Click **Generate**.
5. In the table, next to the new key, click **Download API Key**.
   **You can do this only once.** You get a file named like `AuthKey_ABC123DEFG.p8`. The 10 characters after `AuthKey_`
   are your **Key ID** (it is also shown in the table). Write it in the worksheet.
6. At the **top of the same page**, copy the **Issuer ID** (a long code with dashes) into the worksheet.
7. Move the `.p8` file somewhere safe (a password manager, or a private folder). **Do not email it, post it or put it in
   a public place.**

If the key ever leaks or you lose track of it: on the same page click **Revoke** next to it, and make a new one. Nothing
else is affected.

*Check:* you have the Key ID, the Issuer ID and the `.p8` file.

### 4. Find the Team ID

1. Open **https://developer.apple.com/account** and scroll to **Membership details** (or open the **Membership** tab).
2. Copy the **Team ID** (10 characters, letters and digits) into the worksheet.

*Check:* the worksheet now has the Bundle ID, Key ID, Issuer ID, the `.p8` file and the Team ID.

---

# Part 2: GitHub

## Fastest way (Windows): let a script do it

This replaces steps A to E below with one script that asks for the values from your worksheet, checks each one, makes
your copy of the project, stores the secrets and starts the builds. It only ever talks to **your own** GitHub account and
never shows your key. (The manual steps stay below as a fallback.)

1. Press the **Windows key**, type **PowerShell**, and open **Windows PowerShell**.
2. Install the GitHub tool by pasting this line and pressing Enter (answer **Y** if asked):

   ```
   winget install --id GitHub.cli -e
   ```

   (If Windows says `winget` is unknown, install **App Installer** from the Microsoft Store:
   https://apps.microsoft.com/detail/9nblggh4nns1 , or download GitHub CLI from https://cli.github.com .)
3. **Close the window and open a new PowerShell** (so it finds the new tool). Check it with `gh --version`.
4. Download the script by pasting this one line:

   ```
   Invoke-WebRequest https://raw.githubusercontent.com/jfbobier/alvr-visionos/airframexr-client/scripts/testflight-setup.ps1 -OutFile testflight-setup.ps1
   ```

5. Run it (the file is short and readable if you want to look at it first: open it in Notepad):

   ```
   powershell -ExecutionPolicy Bypass -File .\testflight-setup.ps1
   ```

6. Follow the questions. What to expect:
   - If you are not signed in to GitHub, it shows an 8-character code and opens your browser: sign in, type the code,
     click **Authorize**, then come back to the window.
   - It asks for the `.p8` file (drag the file into the window and press Enter), then the Key ID (it suggests the one
     in the file name), the Issuer ID, the Team ID and the Bundle ID. A wrong-looking value is refused and asked again.
   - It shows a summary: read it, then answer **Y** to store.
   - It offers the **test build** (15 minutes, no Apple involved: say **Y**), then the **upload to TestFlight**.
7. When it says `The build reached Apple`, go on to Part 3. To build again later, just open
   `https://github.com/<you>/alvr-visionos/actions/workflows/testflight.yml` and click **Run workflow**.

*Want to see what it would do first?* Add `-DryRun` at the end of the command in step 5: nothing is changed.

If the script stops with a red **STOP** message, read it: it says what to fix. Run it again afterwards: it skips what is
already done.

## The manual way (the same thing by hand)

GitHub is where the build runs and where the secrets are kept. You need your **own copy** of the project on your own
GitHub account, called a **fork**. (Only the owner of a project can store secrets in it, and the key should stay yours
anyway.) No programming is involved. `<you>` below is your GitHub user name: write it in the worksheet.

### A. Make your copy (the fork)

1. Sign in to **https://github.com** (a free account is fine: https://github.com/signup).
2. Open **https://github.com/jfbobier/alvr-visionos**.
3. At the **top right**, click **Fork** (the button with the little branching icon).
4. On the next page leave everything as it is, check that **Owner** shows your own user name, and click the green
   **Create fork**.
5. After a few seconds you are on `https://github.com/<you>/alvr-visionos`: that is your copy. **From now on work only
   there**, not on `jfbobier`'s page.

*Check:* the page title says `<you>/alvr-visionos` and, under it, `forked from jfbobier/alvr-visionos`.

### B. Switch on the automatic builds in your copy

GitHub turns them off in new forks.

1. In your copy, click the **Actions** tab (top menu, next to **Pull requests**).
2. Click the green **I understand my workflows, go ahead and enable them**.

*Check:* the left side of the Actions page now lists **Build** and **TestFlight**.

### C. Enter the five values

Open **`https://github.com/<you>/alvr-visionos/settings/secrets/actions`** (replace `<you>`), or: your copy >
**Settings** (top menu, far right) > left side **Secrets and variables** > **Actions**.

**Secrets** (the **Secrets** tab; click **New repository secret** once per line, then **Add secret**):

| Name: type it exactly | Value: paste |
|---|---|
| `ASC_KEY_ID` | the Key ID |
| `ASC_ISSUER_ID` | the Issuer ID |
| `ASC_KEY_P8` | open the `.p8` file in Notepad (Windows) or TextEdit (Mac), select everything (Ctrl+A or Cmd+A), copy, paste. It must include the first line `-----BEGIN PRIVATE KEY-----` and the last line `-----END PRIVATE KEY-----` |

**Variables** (the **Variables** tab, next to Secrets; click **New repository variable** once per line, then **Add
variable**):

| Name: type it exactly | Value: paste |
|---|---|
| `APPLE_TEAM_ID` | the Team ID |
| `BUNDLE_ID` | the Bundle ID (for example `io.github.airframexr.client`) |

> **Advice:** names are case sensitive and have no spaces. Secrets are hidden once saved; that is normal. To fix a typo,
> open the secret and click **Update**. Variables are shown in clear and can be edited with the pencil icon.

*Check:* the Secrets tab lists 3 names and the Variables tab lists 2.

### D. Test first without Apple (optional, but do it)

This proves the app builds. It uses none of the values above, so it cannot harm anything.

1. Your copy > **Actions** tab > on the left click **TestFlight**.
2. Click **Run workflow** (grey button on the right). In the box that opens, tick **Only check that the Release archive
   builds**, then click the green **Run workflow**.
3. Reload the page after a few seconds: a new line appears. Click it and wait. After about **10 to 15 minutes** a
   **green tick** means the app builds.

*A red cross:* open the line, copy the page address and send it to whoever helps you.

### E. Upload to TestFlight

1. Your copy > **Actions** > **TestFlight** > **Run workflow**. Direct link:
   **`https://github.com/<you>/alvr-visionos/actions/workflows/testflight.yml`**.
2. **Leave the "Only check" box unticked.** If you like, change the version number (the default `0.1.0` is fine).
3. Click the green **Run workflow** and wait. After about **20 to 30 minutes** a **green tick** means the build reached
   Apple. Apple then sends an email "has completed processing" about 10 to 20 minutes later.

*If the first line of the run turns red with "Missing configuration":* the message names what is missing. Go back to
step C and check the name, spelling and that the value is not empty.

### Getting newer versions of the app later

On your copy's main page click **Sync fork** (above the file list, to the right), then **Update branch**. Then run step E
again.

---

# Part 3: Testers

After the first upload (10 to 20 minutes of processing, you get an email), open
**https://appstoreconnect.apple.com/apps**, click **AirFrameXR**, then the **TestFlight** tab.

1. **Encryption question.** The build shows a yellow **Manage** or "Missing Compliance" warning. Click it and answer the
   encryption question. For this app the answer is the standard one: it only uses the encryption built into the
   operating system's network connections (no custom or proprietary encryption).
2. **Who can test.** Choose one:
   - **Internal testers** (instant, no review, up to 100): people you add at
     **https://appstoreconnect.apple.com/access/users** (button **+**, role **Developer** or **Marketing** is enough; they
     need an Apple ID). Then in TestFlight: **Internal Testing** > **+** > create a group > add them.
     **When you create the group, keep the box _Enable automatic distribution_ ticked** (it is ticked by default; picture:
     https://developer.apple.com/help/app-store-connect/test-a-beta-version/add-internal-testers , dialog "Create New
     Internal Group"). With it, every new build is sent to the group by itself. **Apple does not let you change it
     afterwards**: for a group made without it, create a new group with the box ticked, invite the same people, and delete
     the old one. (Without it, someone has to open the group and click **Add Builds** after every upload.)
   - **External testers** (a community or Discord group: only an email address or a link, no developer account needed):
     **External Testing** > **+** > create a group > **Enable Public Link** and share the link. The **first build of a
     version goes through a short Beta App Review** (usually under a day).
3. **Installing.** Testers install the **TestFlight** app on the Vision Pro (search "TestFlight" in the App Store, or
   https://apps.apple.com/app/testflight/id899247664), open the invitation or the public link, and tap **Install**.

---

# If something goes wrong

| What you see | What it means | What to do |
|---|---|---|
| Run stops at **Missing configuration** | a secret or variable is missing or misnamed | check Part 2 step C: exact names, none empty |
| Signing mentions `com.apple.developer.low-latency-streaming` or "profile doesn't include entitlement" | that capability is not available to your account | **Run workflow** again with **Include the low-latency-streaming entitlement** *unticked*. The app works without it (it only improves network priority) |
| "Choose a certificate to revoke. Your account has reached the maximum number of certificates" (and then "No profiles for ... were found") | every run signs on a fresh machine and creates a certificate; Apple caps their number | **Run workflow** again with **Revoke the certificates earlier runs created** ticked: the run deletes the ones created through the API (named "Created via API") before signing, and prints the list. Or delete them by hand at https://developer.apple.com/account/resources/certificates/list |
| "No profiles for ... were found" alone, or another certificate error | the API key is not **Admin**, or the team has too many distribution certificates | make a new key with **Admin** (Part 1 step 3); or delete an unused **Distribution** certificate at the same page |
| "Authentication failed" / 401 | Key ID, Issuer ID or the `.p8` content is wrong or incomplete | re-paste all three (Part 2 step C); the `.p8` must include its first and last lines |
| "App record not found" or the upload is refused | the app was not created, or its bundle ID differs from `BUNDLE_ID` | compare Part 1 step 2 with the `BUNDLE_ID` variable, letter by letter |
| Upload refused as a duplicate | a build with this version and number already exists | run it again: the build number goes up by itself |
| The run waits forever ("Waiting for a runner") | GitHub has no machine for this job on your account | send the page address to whoever helps you |
| Everything is green but no email | Apple is still processing, or the email went to spam | wait 30 minutes, then check the **TestFlight** tab of the app |

The run page has a **testflight-logs** download (at the bottom, under **Artifacts**) with the full technical log: send
it along when asking for help.

---

## What the build contains

Metal-only client, the AirFrameXR icon, the bundle ID and team from your variables, and no ReplayKit extension (the old
eye-tracking extension was removed with the RealityKit renderer, so no app group is needed either). It is signed with
Apple's cloud-managed distribution certificate: no certificate or profile is stored on GitHub, only the API key.

## For the project owner (not the person doing the upload)

- The recommended bundle ID `io.github.airframexr.client` is tied to the GitHub name **airframexr**. That name is free
  today: claim it by creating a free GitHub organization with that name (https://github.com/account/organizations/new),
  even if the code stays where it is for now.
- A GitHub collaborator on a personal repository cannot add secrets, which is why the Apple account holder forks instead.

## Optional, for developers: upload from a Mac with Xcode instead

You do not need this: the steps above are the supported way. It is an alternative only if you are comfortable with Xcode
and the command line; Xcode signs with the Apple ID you are signed in with and shows every error in place. You need
Xcode 27 and a one-time Rust setup:

1. `brew install rustup cbindgen`, then `rustup-init -y` and `rustup target add aarch64-apple-ios`.
2. `git clone --recursive https://github.com/jfbobier/alvr-visionos` and `cd alvr-visionos`.
3. `sh build_and_repack.sh` (builds the client core and the xcframework; the same steps as the workflow).
4. `open ALVRClient.xcodeproj`. In the **ALVRClient** target > **Signing & Capabilities**: your Team, your bundle ID
   (the app record from Part 1 step 2 must exist). Remove **Low Latency Streaming** there if Xcode says your account
   cannot have it.
5. Destination **Any visionOS Device**, then **Product > Archive**, then **Distribute App > App Store Connect > Upload**.

Both ways produce the same app.
