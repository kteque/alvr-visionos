#!/usr/bin/env python3
"""Fill in the App Store Connect record of the visionOS client and (optionally) submit it to App Review.

Everything the public API allows: version, build, texts, URLs, category, age rating, content rights, price (free),
availability, review details and notes, screenshots, review video. Idempotent: run it again after changing a file in appstore/.
Not possible through the API (a person does these once in the web UI): privacy nutrition label, App Motion Information, EU DSA trader status.

Env: ASC_KEY_ID ASC_ISSUER_ID ASC_KEY_PATH BUNDLE_ID REVIEW_CONTACT_{FIRST,LAST,PHONE,EMAIL}
     VERSION (marketing version, e.g. 1.4.1)  BUILD (build number or empty = newest VALID)  SUBMIT (1 = submit for review)
"""
import hashlib, json, os, sys, time, urllib.error, urllib.parse, urllib.request, glob
import jwt

E = os.environ
KEY = open(E["ASC_KEY_PATH"]).read()
BASE = "https://api.appstoreconnect.apple.com"
HERE = os.path.dirname(os.path.abspath(__file__))
AS = os.path.join(HERE, "..", "appstore")
PRIVACY_URL = "https://github.com/jfbobier/AirFrameXR/blob/main/PRIVACY.md"
SUPPORT_URL = "https://github.com/jfbobier/AirFrameXR/issues"
MARKETING_URL = "https://github.com/jfbobier/AirFrameXR"
problems = []
# Left out for a quick first review (extra regulatory paperwork): mainland China, South Korea, Vietnam, Russia
EXCLUDED = {"CHN", "KOR", "VNM", "RUS"}


def tok():
    return jwt.encode({"iss": E["ASC_ISSUER_ID"], "iat": int(time.time()), "exp": int(time.time()) + 600, "aud": "appstoreconnect-v1"},
                      KEY, algorithm="ES256", headers={"kid": E["ASC_KEY_ID"]})


def call(method, path, body=None, soft=None):
    url = path if path.startswith("http") else BASE + path
    req = urllib.request.Request(url, data=json.dumps(body).encode() if body is not None else None, method=method,
                                 headers={"Authorization": "Bearer " + tok(), "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        detail = e.read().decode()[:1500]
        if soft:
            problems.append(f"{soft}: {method} {path} -> {e.code} {detail}")
            print(f"::warning::{soft}: {e.code} {detail}")
            return None
        print(f"::error::{method} {path} -> {e.code}: {detail}")
        sys.exit(1)


def read(name):
    p = os.path.join(AS, name)
    return open(p, encoding="utf-8").read().strip() if os.path.exists(p) else ""


def step(msg):
    print(f"\n== {msg}", flush=True)


def upload_asset(create_path, create_body, filepath, soft):
    """Reserve + upload + commit an asset (screenshot / review attachment). Returns the asset id."""
    data = open(filepath, "rb").read()
    body = json.loads(json.dumps(create_body))
    body["data"]["attributes"].update({"fileName": os.path.basename(filepath), "fileSize": len(data)})
    r = call("POST", create_path, body, soft=soft)
    if not r:
        return None
    asset = r["data"]
    for op in asset["attributes"]["uploadOperations"]:
        chunk = data[op["offset"]:op["offset"] + op["length"]]
        req = urllib.request.Request(op["url"], data=chunk, method=op["method"], headers={h["name"]: h["value"] for h in op["requestHeaders"]})
        urllib.request.urlopen(req).read()
    kind = asset["type"]
    call("PATCH", f"/v1/{kind}/{asset['id']}", {"data": {"type": kind, "id": asset["id"], "attributes": {"uploaded": True, "sourceFileChecksum": hashlib.md5(data).hexdigest()}}}, soft=soft)
    return asset["id"]


# ---- app, version, build
app = call("GET", f"/v1/apps?filter[bundleId]={urllib.parse.quote(E['BUNDLE_ID'])}")["data"][0]
aid = app["id"]
version = E["VERSION"]
step(f"app {aid}, version {version}")
vers = call("GET", f"/v1/apps/{aid}/appStoreVersions?filter[platform]=VISION_OS&limit=10")["data"]
if E.get("STATUS_ONLY") == "1":
    for v in vers:
        print("STATUS", v["attributes"]["versionString"], v["attributes"]["appStoreState"])
    subs = call("GET", f"/v1/apps/{aid}/reviewSubmissions?filter[platform]=VISION_OS&limit=10")["data"]
    for r in subs:
        print("SUBMISSION", r["id"], r["attributes"].get("state"), r["attributes"].get("submittedDate"))
    sys.exit(0)
editable = [v for v in vers if v["attributes"]["appStoreState"] in ("PREPARE_FOR_SUBMISSION", "DEVELOPER_REJECTED", "REJECTED", "METADATA_REJECTED", "INVALID_BINARY")]
if not editable:
    if any(v["attributes"]["appStoreState"] in ("WAITING_FOR_REVIEW", "IN_REVIEW") for v in vers):
        print("::error::a visionOS version is already in review"); sys.exit(1)
    # nothing editable (the last version is approved or live): open the next one
    print("no editable version, creating", version)
    created = call("POST", "/v1/appStoreVersions", {"data": {"type": "appStoreVersions", "attributes": {
        "platform": "VISION_OS", "versionString": version, "releaseType": "MANUAL"},
        "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})
    editable = [created["data"]]
ver = editable[0]
vid = ver["id"]
call("PATCH", f"/v1/appStoreVersions/{vid}", {"data": {"type": "appStoreVersions", "id": vid, "attributes": {
    "versionString": version, "releaseType": "MANUAL", "copyright": "2026 AirFrameXR"}}})
print("version set to", version, "manual release")

builds = call("GET", f"/v1/builds?filter[app]={aid}&filter[preReleaseVersion.version]={urllib.parse.quote(version)}&limit=200")["data"]
ok = [b for b in builds if b["attributes"]["processingState"] == "VALID" and not b["attributes"]["expired"]]
if E.get("BUILD"):
    ok = [b for b in ok if b["attributes"]["version"] == E["BUILD"]]
if not ok:
    print(f"::error::no valid build for {version} {E.get('BUILD','')}"); sys.exit(1)
ok.sort(key=lambda b: int(b["attributes"]["version"]))
build = ok[-1]
call("PATCH", f"/v1/appStoreVersions/{vid}/relationships/build", {"data": {"type": "builds", "id": build["id"]}})
print("build attached:", version, build["attributes"]["version"], "usesNonExemptEncryption =", build["attributes"].get("usesNonExemptEncryption"))

# ---- content rights, texts
call("PATCH", f"/v1/apps/{aid}", {"data": {"type": "apps", "id": aid, "attributes": {"contentRightsDeclaration": "DOES_NOT_USE_THIRD_PARTY_CONTENT"}}}, soft="content rights")
step("texts")
for loc in call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"]:
    call("PATCH", f"/v1/appStoreVersionLocalizations/{loc['id']}", {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"], "attributes": {
        "description": read("description.txt"), "keywords": read("keywords.txt"), "whatsNew": read("whats_new.txt"), "supportUrl": SUPPORT_URL, "marketingUrl": MARKETING_URL}}}, soft="version texts")
    print("localization", loc["attributes"]["locale"], "filled")

# ---- app info: category, subtitle, privacy URL, age rating
step("app info")
info = call("GET", f"/v1/apps/{aid}/appInfos")["data"][0]
call("PATCH", f"/v1/appInfos/{info['id']}", {"data": {"type": "appInfos", "id": info["id"], "relationships": {
    "primaryCategory": {"data": {"type": "appCategories", "id": "UTILITIES"}}}}}, soft="category")
for loc in call("GET", f"/v1/appInfos/{info['id']}/appInfoLocalizations")["data"]:
    call("PATCH", f"/v1/appInfoLocalizations/{loc['id']}", {"data": {"type": "appInfoLocalizations", "id": loc["id"], "attributes": {
        "subtitle": "Wireless PC VR over your LAN", "privacyPolicyUrl": PRIVACY_URL}}}, soft="subtitle/privacy url")
none_enum = ["alcoholTobaccoOrDrugUseOrReferences", "contests", "gamblingSimulated", "gunsOrOtherWeapons", "horrorOrFearThemes",
             "matureOrSuggestiveThemes", "medicalOrTreatmentInformation", "profanityOrCrudeHumor", "sexualContentGraphicAndNudity",
             "sexualContentOrNudity", "violenceCartoonOrFantasy", "violenceRealistic", "violenceRealisticProlongedGraphicOrSadistic"]
no_bool = ["advertising", "gambling", "lootBox", "messagingAndChat", "parentalControls", "ageAssurance", "unrestrictedWebAccess",
           "userGeneratedContent", "healthOrWellnessTopics", "socialMedia"]
attrs = {k: "NONE" for k in none_enum}
attrs.update({k: False for k in no_bool})
call("PATCH", f"/v1/ageRatingDeclarations/{info['id']}", {"data": {"type": "ageRatingDeclarations", "id": info["id"], "attributes": attrs}}, soft="age rating")
print("category Utilities, subtitle, privacy URL, age rating (all none) set")

# ---- review details
step("review details")
rd = {"contactFirstName": E["REVIEW_CONTACT_FIRST"], "contactLastName": E["REVIEW_CONTACT_LAST"], "contactPhone": E["REVIEW_CONTACT_PHONE"],
      "contactEmail": E["REVIEW_CONTACT_EMAIL"], "demoAccountRequired": False, "notes": read("review_notes.txt") + ("\n\nDEMO VIDEOS (real devices, unlisted YouTube links):\n" + read("review_video_url.txt") if read("review_video_url.txt") else "")}
cur = call("GET", f"/v1/appStoreVersions/{vid}/appStoreReviewDetail")
if cur and cur.get("data"):
    rid = cur["data"]["id"]
    call("PATCH", f"/v1/appStoreReviewDetails/{rid}", {"data": {"type": "appStoreReviewDetails", "id": rid, "attributes": rd}}, soft="review detail")
else:
    r = call("POST", "/v1/appStoreReviewDetails", {"data": {"type": "appStoreReviewDetails", "attributes": rd, "relationships": {
        "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}}, soft="review detail")
    rid = r["data"]["id"] if r else None
for f in sorted(glob.glob(os.path.join(AS, "review", "*"))):
    if rid and not f.endswith(".gitkeep"):
        upload_asset("/v1/appStoreReviewAttachments", {"data": {"type": "appStoreReviewAttachments", "attributes": {}, "relationships": {
            "appStoreReviewDetail": {"data": {"type": "appStoreReviewDetails", "id": rid}}}}}, f, f"review attachment {os.path.basename(f)}")
        print("review attachment uploaded:", os.path.basename(f))

# ---- screenshots (replace the set)
step("screenshots")
shots = sorted(glob.glob(os.path.join(AS, "screenshots", "*.png")) + glob.glob(os.path.join(AS, "screenshots", "*.jpg")))
if shots:
    loc = call("GET", f"/v1/appStoreVersions/{vid}/appStoreVersionLocalizations")["data"][0]
    sets = call("GET", f"/v1/appStoreVersionLocalizations/{loc['id']}/appScreenshotSets")["data"]
    for s in sets:
        if s["attributes"]["screenshotDisplayType"] == "APP_APPLE_VISION_PRO":
            call("DELETE", f"/v1/appScreenshotSets/{s['id']}")
    sset = call("POST", "/v1/appScreenshotSets", {"data": {"type": "appScreenshotSets", "attributes": {"screenshotDisplayType": "APP_APPLE_VISION_PRO"},
            "relationships": {"appStoreVersionLocalization": {"data": {"type": "appStoreVersionLocalizations", "id": loc["id"]}}}}}, soft="screenshot set")
    if sset:
        for f in shots[:10]:
            upload_asset("/v1/appScreenshots", {"data": {"type": "appScreenshots", "attributes": {}, "relationships": {
                "appScreenshotSet": {"data": {"type": "appScreenshotSets", "id": sset["data"]["id"]}}}}}, f, f"screenshot {os.path.basename(f)}")
            print("screenshot uploaded:", os.path.basename(f))
else:
    print("no file in appstore/screenshots/: skipped")

# ---- price: free; availability: all territories except EXCLUDED, new territories not added automatically
step("price and availability")
pts = call("GET", f"/v1/apps/{aid}/appPricePoints?filter[territory]=USA&limit=200", soft="price points")
free = next((p for p in (pts or {"data": []})["data"] if float(p["attributes"].get("customerPrice") or 1) == 0.0), None)
if free:
    call("POST", "/v1/appPriceSchedules", {"data": {"type": "appPriceSchedules", "relationships": {
        "app": {"data": {"type": "apps", "id": aid}}, "baseTerritory": {"data": {"type": "territories", "id": "USA"}},
        "manualPrices": {"data": [{"type": "appPrices", "id": "${p1}"}]}}},
        "included": [{"type": "appPrices", "id": "${p1}", "attributes": {"startDate": None}, "relationships": {
            "appPricePoint": {"data": {"type": "appPricePoints", "id": free["id"]}}}}]}, soft="price schedule")
    print("price: free")
terr = []
url = "/v1/territories?limit=200"
while url:
    t = call("GET", url, soft="territories")
    if not t:
        break
    terr += [x["id"] for x in t["data"]]
    url = t.get("links", {}).get("next")
existing = None
try:
    existing = call("GET", f"/v2/appAvailabilities/{aid}/territoryAvailabilities?include=territory&limit=200")
except SystemExit:
    existing = None
if existing and existing.get("data"):
    # already created (the API cannot create it twice): switch single territories on/off
    n = 0
    url = f"/v2/appAvailabilities/{aid}/territoryAvailabilities?include=territory&limit=200"
    while url:
        page = call("GET", url)
        for ta in page["data"]:
            tid = ta["relationships"]["territory"]["data"]["id"]
            want = tid not in EXCLUDED
            if ta["attributes"].get("available") != want:
                call("PATCH", f"/v1/territoryAvailabilities/{ta['id']}", {"data": {"type": "territoryAvailabilities", "id": ta["id"], "attributes": {"available": want}}}, soft="territory " + tid)
                n += 1
        url = page.get("links", {}).get("next")
    print("availability already existed:", n, "territory switches changed; excluded:", sorted(EXCLUDED))
elif terr:
    call("POST", "/v2/appAvailabilities", {"data": {"type": "appAvailabilities", "attributes": {"availableInNewTerritories": False}, "relationships": {
        "app": {"data": {"type": "apps", "id": aid}},
        "territoryAvailabilities": {"data": [{"type": "territoryAvailabilities", "id": f"${{t{i}}}"} for i in range(len(terr))]}}},
        "included": [{"type": "territoryAvailabilities", "id": f"${{t{i}}}", "attributes": {"available": t not in EXCLUDED}, "relationships": {
            "territory": {"data": {"type": "territories", "id": t}}}} for i, t in enumerate(terr)]}, soft="availability")
    print("availability created; excluded:", sorted(EXCLUDED), "; new territories are NOT added automatically")

# ---- readiness report and submission
step("readiness")
if problems:
    print(f"{len(problems)} step(s) reported a problem (see warnings above)")
print("Done by hand once in App Store Connect (no public API): App Privacy (Data Not Collected) + publish, App Motion Information, EU DSA trader status.")
if E.get("SUBMIT") == "1":
    step("submit for review")
    open_subs = [x for x in call("GET", f"/v1/apps/{aid}/reviewSubmissions?filter[state]=READY_FOR_REVIEW&filter[platform]=VISION_OS")["data"]]
    if open_subs:
        sid = open_subs[0]["id"]
        print("reusing the draft review submission", sid)
    else:
        sub = call("POST", "/v1/reviewSubmissions", {"data": {"type": "reviewSubmissions", "attributes": {"platform": "VISION_OS"},
                  "relationships": {"app": {"data": {"type": "apps", "id": aid}}}}})
        sid = sub["data"]["id"]
    items = call("GET", f"/v1/reviewSubmissions/{sid}/items")["data"]
    if not items:
        call("POST", "/v1/reviewSubmissionItems", {"data": {"type": "reviewSubmissionItems", "relationships": {
            "reviewSubmission": {"data": {"type": "reviewSubmissions", "id": sid}}, "appStoreVersion": {"data": {"type": "appStoreVersions", "id": vid}}}}})
    call("PATCH", f"/v1/reviewSubmissions/{sid}", {"data": {"type": "reviewSubmissions", "id": sid, "attributes": {"submitted": True}}})
    print("SUBMITTED to App Review")
else:
    print("dry run: filled in, NOT submitted (run with submit = true)")
