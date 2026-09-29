# Hướng dẫn ký, notarize và đóng gói SkyPC cho macOS

Tài liệu này tổng hợp toàn bộ quy trình đã thực hiện trong conversation: từ việc chuẩn bị Apple Developer, tạo **Developer ID Application certificate**, ký binary/app bằng `codesign`, thiết lập `notarytool`, notarize, staple ticket, cho tới đóng gói thành `SkyPC.dmg` để phát hành trực tiếp ngoài Mac App Store.

> Phạm vi của tài liệu này là **direct distribution ngoài Mac App Store** bằng **Developer ID + Apple Notary Service**. Đây không phải quy trình submit lên Mac App Store.

---

## Mục lục

1. [Mô hình phân phối](#1-mô-hình-phân-phối)
2. [Thông tin đang dùng trong ví dụ](#2-thông-tin-đang-dùng-trong-ví-dụ)
3. [Chuẩn bị máy Mac](#3-chuẩn-bị-máy-mac)
4. [Tạo CSR](#4-tạo-csr)
5. [Tạo Developer ID Application certificate](#5-tạo-developer-id-application-certificate)
6. [Import certificate vào login Keychain](#6-import-certificate-vào-login-keychain)
7. [Kiểm tra code-signing identity](#7-kiểm-tra-code-signing-identity)
8. [Ký thử raw binary `skypc`](#8-ký-thử-raw-binary-skypc)
9. [Tạo credential cho Notary Service](#9-tạo-credential-cho-notary-service)
10. [Notarize raw binary để test pipeline](#10-notarize-raw-binary-để-test-pipeline)
11. [Tạo `SkyPC.app`](#11-tạo-skypcapp)
12. [Tạo `Info.plist`](#12-tạo-infoplist)
13. [Ký `SkyPC.app`](#13-ký-skypcapp)
14. [Notarize `SkyPC.app`](#14-notarize-skypcapp)
15. [Staple và verify `SkyPC.app`](#15-staple-và-verify-skypcapp)
16. [Tạo `SkyPC.dmg`](#16-tạo-skypcdmg)
17. [Ký `SkyPC.dmg`](#17-ký-skypcdmg)
18. [Notarize và staple `SkyPC.dmg`](#18-notarize-và-staple-skypcdmg)
19. [Kiểm tra Gatekeeper](#19-kiểm-tra-gatekeeper)
20. [Test như user thật](#20-test-như-user-thật)
21. [USB, DriverKit, App Sandbox và entitlement](#21-usb-driverkit-app-sandbox-và-entitlement)
22. [Phân biệt direct distribution và Mac App Store](#22-phân-biệt-direct-distribution-và-mac-app-store)
23. [Các lỗi đã gặp và cách xử lý](#23-các-lỗi-đã-gặp-và-cách-xử-lý)
24. [Pipeline production đề xuất](#24-pipeline-production-đề-xuất)
25. [Checklist release](#25-checklist-release)

---

# 1. Mô hình phân phối

Quy trình trong tài liệu này là:

```text
Build binary
   ↓
SkyPC.app
   ↓
Developer ID Application signing
   ↓
Hardened Runtime
   ↓
SkyPC.dmg
   ↓
Developer ID signing
   ↓
Apple Notary Service
   ↓
Accepted
   ↓
Staple ticket
   ↓
Gatekeeper verify
   ↓
Release cho user
```

Điểm quan trọng:

- **Không submit lên App Store Connect**.
- App được phát hành trực tiếp từ website/CDN/updater của công ty.
- `Developer ID Application` dùng để xác minh developer.
- `notarytool` gửi artifact lên Apple để scan/notarize.
- `stapler` gắn notarization ticket vào `.app` hoặc `.dmg`.

---

# 2. Thông tin đang dùng trong ví dụ

Trong quá trình thực hiện, team có:

```text
Company:
Sub2s Technology and Media Broadcasting Joint Stock Company

Team ID:
P4F9DNFZ68
```

Developer ID Application identity đã tạo:

```text
Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
```

Fingerprint/identity hash trên máy ký:

```text
F0A8C68A074C696C9EECB33069FC797CC79B7C5A
```

Bundle ID dùng trong ví dụ:

```text
com.sub2s.skypc
```

> Trước production chính thức, nên chốt Bundle ID một lần và giữ ổn định lâu dài.

---

# 3. Chuẩn bị máy Mac

Cài Xcode và Command Line Tools.

Kiểm tra:

```bash
xcode-select -p
xcrun codesign --version
xcrun notarytool --version
```

Nếu cần chọn Xcode hiện tại:

```bash
sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
```

Giả sử file binary dev đưa là:

```text
~/SkyPC-Workspace/Mac-signing/skypc
```

Kiểm tra:

```bash
cd ~/SkyPC-Workspace/Mac-signing
file ./skypc
```

Trong case thực tế:

```text
Mach-O 64-bit executable arm64
```

---

# 4. Tạo CSR

Trên **chính máy Mac sẽ dùng để ký**, mở:

```text
Keychain Access
→ Certificate Assistant
→ Request a Certificate From a Certificate Authority...
```

Điền:

```text
User Email Address:
email Apple Developer/Account Holder

Common Name:
SkyPC Developer ID

CA Email Address:
để trống
```

Chọn:

```text
Saved to disk
```

Lưu file ví dụ:

```text
SkyPC.certSigningRequest
```

Lưu ý:

- `Common Name` chỉ là label để nhận diện key/CSR.
- Không cần điền Team ID hay Developer ID thật vào `Common Name`.
- Khi tạo CSR, private key được sinh ra trên máy Mac này.

---

# 5. Tạo Developer ID Application certificate

Đăng nhập bằng **Account Holder** tại Apple Developer Portal.

Đi theo:

```text
Certificates, Identifiers & Profiles
→ Certificates
→ +
→ Software
→ Developer ID
→ Developer ID Application
```

Không chọn nhầm:

```text
Apple Development
Apple Distribution
Mac Development
Mac App Distribution
Developer ID Installer
```

Upload:

```text
SkyPC.certSigningRequest
```

Generate và Download certificate `.cer`.

Ví dụ certificate được tạo:

```text
Developer ID Application:
Sub2s Technology and Media Broadcasting Joint Stock Company
(P4F9DNFZ68)
```

---

# 6. Import certificate vào login Keychain

## Cách GUI

Trong Keychain Access:

1. Chọn **login** ở cột trái.
2. Chọn `File → Import Items...`.
3. Chọn file `.cer`.
4. Import vào **login**, không import vào `iCloud` hoặc `Local Items`.

## Cách Terminal

Nếu GUI lỗi hoặc bị treo:

```bash
security import ~/Downloads/developerID_application.cer \
  -k ~/Library/Keychains/login.keychain-db
```

Nếu Keychain Access bị treo:

```bash
killall "Keychain Access"
```

Nếu vẫn không thoát:

```bash
sudo killall -9 "Keychain Access"
```

---

# 7. Kiểm tra code-signing identity

Chạy:

```bash
security find-identity -v -p codesigning
```

Kết quả thực tế đã đạt:

```text
1) ... "Apple Development: Phan Khoa (...)"
2) F0A8C68A074C696C9EECB33069FC797CC79B7C5A \
   "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)"
3) ... "Apple Development: Phan Khoa (...)"
```

Cho production direct distribution, dùng identity:

```text
F0A8C68A074C696C9EECB33069FC797CC79B7C5A
```

Hoặc dùng full certificate name.

Quan trọng:

- Certificate phải có **private key** tương ứng trong Keychain.
- Nếu có certificate nhưng không có private key thì không ký được.

---

# 8. Ký thử raw binary `skypc`

Backup binary gốc:

```bash
cd ~/SkyPC-Workspace/Mac-signing
cp ./skypc ./skypc.unsigned-backup
```

Ký bằng Developer ID Application:

```bash
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "F0A8C68A074C696C9EECB33069FC797CC79B7C5A" \
  ./skypc
```

Giải thích:

```text
--force
    ghi đè ad-hoc/linker signature cũ

--options runtime
    bật Hardened Runtime

--timestamp
    lấy secure timestamp của Apple

--sign
    chọn Developer ID Application identity
```

Verify:

```bash
codesign --verify --strict --verbose=4 ./skypc
```

Kết quả tốt:

```text
./skypc: valid on disk
./skypc: satisfies its Designated Requirement
```

Xem chi tiết:

```bash
codesign -dvvv ./skypc 2>&1
```

Cần thấy:

```text
Authority=Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=P4F9DNFZ68
Timestamp=...
flags=0x10000(runtime)
```

---

# 9. Tạo credential cho Notary Service

## 9.1 Tạo app-specific password

Vào:

```text
account.apple.com
→ Sign-In and Security
→ App-Specific Passwords
```

Tạo password ví dụ tên:

```text
SkyPC Notary
```

Có thể dùng Apple ID dev nếu account đó:

- thuộc đúng Team `P4F9DNFZ68`
- có quyền notarization phù hợp

Không bắt buộc app-specific password phải được tạo từ Account Holder nếu dev account có quyền hợp lệ.

## 9.2 Lưu credential vào Keychain

```bash
xcrun notarytool store-credentials "SkyPC-Notary" \
  --apple-id "YOUR_APPLE_ID_EMAIL" \
  --team-id "P4F9DNFZ68" \
  --password "APP-SPECIFIC-PASSWORD"
```

Test:

```bash
xcrun notarytool history \
  --keychain-profile "SkyPC-Notary"
```

Nếu chưa submit gì có thể nhận:

```text
No submission history.
```

Điều này vẫn có nghĩa là credential đã dùng được.

---

# 10. Notarize raw binary để test pipeline

Đây là bước test pipeline ban đầu, không phải format production cuối cùng.

Đóng ZIP:

```bash
cd ~/SkyPC-Workspace/Mac-signing
rm -f ./skypc-notarize.zip

ditto -c -k --keepParent \
  ./skypc \
  ./skypc-notarize.zip
```

Submit:

```bash
xcrun notarytool submit \
  ./skypc-notarize.zip \
  --keychain-profile "SkyPC-Notary" \
  --wait
```

Kết quả thực tế đã đạt:

```text
status: Accepted
```

Nếu `Invalid`:

```bash
xcrun notarytool log <SUBMISSION_ID> \
  --keychain-profile "SkyPC-Notary"
```

Lưu ý:

- Standalone Mach-O có thể notarize.
- Nhưng raw executable không phải app bundle hoàn chỉnh.
- `spctl --assess --type execute ./skypc` có thể trả:

```text
rejected (the code is valid but does not seem to be an app)
```

Đây không có nghĩa notarization thất bại; nó chỉ phản ánh rằng file không phải `.app` bundle.

---

# 11. Tạo `SkyPC.app`

Tạo app bundle:

```bash
cd ~/SkyPC-Workspace/Mac-signing

rm -rf SkyPC.app

mkdir -p SkyPC.app/Contents/MacOS
mkdir -p SkyPC.app/Contents/Resources

cp ./skypc SkyPC.app/Contents/MacOS/skypc
chmod 755 SkyPC.app/Contents/MacOS/skypc
```

Cấu trúc:

```text
SkyPC.app/
└── Contents/
    ├── Info.plist
    ├── MacOS/
    │   └── skypc
    └── Resources/
```

---

# 12. Tạo `Info.plist`

Tạo file:

```bash
cat > SkyPC.app/Contents/Info.plist <<'PLIST_END'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>

    <key>CFBundleName</key>
    <string>SkyPC</string>

    <key>CFBundleDisplayName</key>
    <string>SkyPC</string>

    <key>CFBundleIdentifier</key>
    <string>com.sub2s.skypc</string>

    <key>CFBundleExecutable</key>
    <string>skypc</string>

    <key>CFBundlePackageType</key>
    <string>APPL</string>

    <key>CFBundleShortVersionString</key>
    <string>0.1.0</string>

    <key>CFBundleVersion</key>
    <string>1</string>

    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>NSCameraUsageDescription</key>
    <string>SkyPC requires camera access for remote camera functionality.</string>

    <key>NSMicrophoneUsageDescription</key>
    <string>SkyPC requires microphone access for remote audio functionality.</string>

</dict>
</plist>
PLIST_END
```

Kiểm tra syntax:

```bash
plutil -lint SkyPC.app/Contents/Info.plist
```

Kết quả:

```text
SkyPC.app/Contents/Info.plist: OK
```

Kiểm tra nội dung:

```bash
plutil -p SkyPC.app/Contents/Info.plist
```

---

# 13. Ký `SkyPC.app`

Trước signing có thể dọn metadata không cần thiết:

```bash
xattr -cr SkyPC.app
```

Ký app:

```bash
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "F0A8C68A074C696C9EECB33069FC797CC79B7C5A" \
  SkyPC.app
```

Verify:

```bash
codesign --verify \
  --deep \
  --strict \
  --verbose=4 \
  SkyPC.app
```

Cần thấy:

```text
SkyPC.app: valid on disk
SkyPC.app: satisfies its Designated Requirement
```

Xem detail:

```bash
codesign -dvvv SkyPC.app 2>&1
```

Cần thấy:

```text
Identifier=com.sub2s.skypc
Authority=Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
TeamIdentifier=P4F9DNFZ68
flags=0x10000(runtime)
Timestamp=...
```

Test app:

```bash
open SkyPC.app
```

Nếu cần xem stdout/stderr:

```bash
./SkyPC.app/Contents/MacOS/skypc
```

Trong quá trình thực hiện, `SkyPC.app` đã chạy tốt.

---

# 14. Notarize `SkyPC.app`

Tạo ZIP để submit:

```bash
cd ~/SkyPC-Workspace/Mac-signing
rm -f SkyPC-app-notarize.zip

ditto \
  -c \
  -k \
  --keepParent \
  SkyPC.app \
  SkyPC-app-notarize.zip
```

Submit:

```bash
xcrun notarytool submit \
  SkyPC-app-notarize.zip \
  --keychain-profile "SkyPC-Notary" \
  --wait
```

Kết quả thực tế đã đạt:

```text
status: Accepted
```

Nếu lỗi:

```bash
xcrun notarytool log <SUBMISSION_ID> \
  --keychain-profile "SkyPC-Notary"
```

---

# 15. Staple và verify `SkyPC.app`

Sau khi notarization `Accepted`:

```bash
xcrun stapler staple SkyPC.app
```

Validate:

```bash
xcrun stapler validate SkyPC.app
```

Kết quả đã đạt:

```text
The validate action worked!
```

Verify signature lần nữa:

```bash
codesign --verify \
  --deep \
  --strict \
  --verbose=4 \
  SkyPC.app
```

---

# 16. Tạo `SkyPC.dmg`

Tạo thư mục staging:

```bash
cd ~/SkyPC-Workspace/Mac-signing

rm -rf dmg-root
mkdir dmg-root
```

Copy app vào:

```bash
ditto SkyPC.app dmg-root/SkyPC.app
```

Tạo shortcut Applications:

```bash
ln -s /Applications dmg-root/Applications
```

Kiểm tra:

```bash
ls -la dmg-root
```

Cần thấy:

```text
SkyPC.app
Applications -> /Applications
```

Tạo DMG:

```bash
rm -f SkyPC.dmg

hdiutil create \
  -volname "SkyPC" \
  -srcfolder dmg-root \
  -ov \
  -format UDZO \
  SkyPC.dmg
```

Trên macOS mới có thể xuất hiện warning dạng:

```text
'hdiutil create -volname -format ...' is deprecated
```

Đây chỉ là warning, không có nghĩa DMG bị lỗi.

Verify DMG:

```bash
hdiutil verify SkyPC.dmg
```

---

# 17. Ký `SkyPC.dmg`

Ký DMG bằng **Developer ID Application**:

```bash
codesign \
  --force \
  --timestamp \
  --sign "F0A8C68A074C696C9EECB33069FC797CC79B7C5A" \
  --identifier "com.sub2s.skypc.dmg" \
  SkyPC.dmg
```

Verify:

```bash
codesign --verify --verbose=4 SkyPC.dmg
```

Xem detail:

```bash
codesign -dvvv SkyPC.dmg 2>&1
```

Cần thấy:

```text
Authority=Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=P4F9DNFZ68
Timestamp=...
```

---

# 18. Notarize và staple `SkyPC.dmg`

Submit chính DMG:

```bash
xcrun notarytool submit \
  SkyPC.dmg \
  --keychain-profile "SkyPC-Notary" \
  --wait
```

Mục tiêu:

```text
status: Accepted
```

Nếu `Invalid`:

```bash
xcrun notarytool log <SUBMISSION_ID> \
  --keychain-profile "SkyPC-Notary"
```

Sau khi `Accepted`:

```bash
xcrun stapler staple SkyPC.dmg
```

Validate:

```bash
xcrun stapler validate SkyPC.dmg
```

Kết quả mong muốn:

```text
The validate action worked!
```

---

# 19. Kiểm tra Gatekeeper

## Kiểm tra DMG

```bash
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  SkyPC.dmg
```

## Mount DMG

```bash
hdiutil attach SkyPC.dmg
```

Thông thường volume nằm ở:

```text
/Volumes/SkyPC
```

## Kiểm tra app bên trong

```bash
spctl \
  --assess \
  --type execute \
  --verbose=4 \
  "/Volumes/SkyPC/SkyPC.app"
```

Mục tiêu:

```text
accepted
source=Notarized Developer ID
```

---

# 20. Test như user thật

Mở DMG:

```bash
open SkyPC.dmg
```

Finder nên hiện:

```text
SkyPC.app  →  Applications
```

Kéo app sang `/Applications`.

Chạy:

```bash
open /Applications/SkyPC.app
```

Nên test tối thiểu:

```text
UI
streaming
video decode
keyboard
mouse
controller
USB enumeration
USB hotplug
USB open/interface claim
camera
microphone
```

Tốt nhất test thêm trên **một Mac khác** chưa từng chạy SkyPC.

---

# 21. USB, DriverKit, App Sandbox và entitlement

Trong binary đã kiểm tra, SkyPC có dấu hiệu dùng:

```text
IOKit
IOUSBDevice
IOHIDManager
nusb::platform::macos_iokit
USB hotplug
physical USB device
```

Nhưng hiện tại chưa có bằng chứng app đang cần:

```text
DriverKit
Virtual HID
Virtual USB driver
App Sandbox USB entitlement
```

Vì vậy pipeline ban đầu nên để:

```text
Hardened Runtime = ON
App Sandbox      = OFF
DriverKit        = NONE
USB entitlement  = NONE
```

Không nên tự ý thêm:

```xml
<key>com.apple.security.device.usb</key>
<true/>
```

Không nên tự ý bật:

```xml
<key>com.apple.security.app-sandbox</key>
<true/>
```

Không nên xin DriverKit entitlement nếu chưa có requirement rõ ràng.

Nếu USB fail sau khi signed/notarized, debug bằng log:

```bash
log stream \
  --style compact \
  --predicate 'process == "skypc"'
```

Hoặc:

```bash
log stream \
  --style compact \
  --predicate 'eventMessage CONTAINS[c] "skypc"'
```

Tìm các dấu hiệu:

```text
kIOReturnNotPermitted
sandbox deny
TCC deny
IOServiceOpen failure
USB interface claim failure
```

---

# 22. Phân biệt direct distribution và Mac App Store

## Direct distribution

Đây là quy trình đang dùng:

```text
Developer ID Application
→ Hardened Runtime
→ Notary Service
→ DMG/PKG/ZIP
→ phát hành từ website/CDN riêng
```

Ưu điểm:

- Không bị ràng buộc bởi App Sandbox của Mac App Store.
- Phù hợp app desktop chuyên dụng, remote desktop, USB/IOKit, helper, updater riêng.

## Mac App Store

Nếu muốn submit lên App Store:

```text
Apple Distribution / Mac App Store signing
→ App Sandbox bắt buộc
→ App Store Connect
→ App Review
→ Apple phân phối app
```

Đây là pipeline khác hoàn toàn.

---

# 23. Các lỗi đã gặp và cách xử lý

## 23.1 Import certificate lỗi `-25294`

Triệu chứng:

```text
Unable to import Developer ID Application...
Error: -25294
```

Nguyên nhân thực tế: đang import vào `iCloud` Keychain thay vì `login`.

Cách xử lý:

```text
Keychain Access
→ chọn login
→ File
→ Import Items...
```

Hoặc:

```bash
security import certificate.cer \
  -k ~/Library/Keychains/login.keychain-db
```

---

## 23.2 Keychain Access bị treo

```bash
killall "Keychain Access"
```

Nếu cần:

```bash
sudo killall -9 "Keychain Access"
```

---

## 23.3 Gatekeeper báo raw binary không phải app

```text
rejected (the code is valid but does not seem to be an app)
```

Nguyên nhân: raw Mach-O không phải `.app` bundle.

Cách đúng: đóng thành `SkyPC.app`, ký/notarize/staple bundle.

---

## 23.4 App đã ký nhưng Gatekeeper vẫn cảnh báo malware

Nếu chỉ codesign mà chưa notarize, có thể gặp:

```text
Apple could not verify “skypc” is free of malware...
```

Đây không phải lỗi signature.

Cần notarization.

---

## 23.5 `No submission history.`

Khi chạy:

```bash
xcrun notarytool history \
  --keychain-profile "SkyPC-Notary"
```

Nếu ra:

```text
No submission history.
```

Không phải lỗi. Nó chỉ có nghĩa chưa từng submit artifact trước đó.

---

## 23.6 `hdiutil create` deprecated warning

Có thể thấy:

```text
hdiutil: WARNING: 'hdiutil create -volname -format ...' is deprecated
```

Artifact vẫn có thể được tạo hợp lệ.

Trong tương lai có thể chuyển pipeline sang lệnh `diskutil image create ...` tương ứng trên macOS mới.

---

# 24. Pipeline production đề xuất

Sau khi đã xác nhận toàn bộ flow, team nên tự động hóa thành script/CI.

## Flow tối giản cho release DMG

```text
Build skypc
    ↓
Create SkyPC.app
    ↓
Copy binary + resources
    ↓
Generate Info.plist
    ↓
Sign nested code nếu có
    ↓
Sign SkyPC.app
    ↓
Verify SkyPC.app
    ↓
Create SkyPC.dmg
    ↓
Sign SkyPC.dmg
    ↓
notarytool submit SkyPC.dmg
    ↓
Accepted
    ↓
stapler staple SkyPC.dmg
    ↓
Gatekeeper verify
    ↓
Publish
```

Nếu artifact cuối luôn là DMG, về production có thể tránh notarize app riêng trước đó; chỉ cần:

```text
sign app
→ create DMG
→ sign DMG
→ notarize outermost DMG
→ staple DMG
```

Vẫn phải đảm bảo toàn bộ code bên trong app đã được ký đúng.

---

# 25. Checklist release

Trước mỗi release, kiểm tra:

```text
[ ] Binary đúng architecture
[ ] Version đúng
[ ] Bundle ID đúng
[ ] Info.plist hợp lệ
[ ] Camera usage text đúng
[ ] Microphone usage text đúng
[ ] Developer ID Application certificate còn hạn
[ ] Private key có trên signing machine/CI
[ ] Hardened Runtime bật
[ ] App Sandbox không bật nhầm
[ ] Không thêm entitlement thừa
[ ] codesign verify pass
[ ] App launch bình thường
[ ] USB hoạt động
[ ] Input hoạt động
[ ] Camera/microphone hoạt động
[ ] DMG được ký
[ ] notarytool status = Accepted
[ ] stapler validate pass
[ ] Gatekeeper assess pass
[ ] Test trên Mac sạch
```

---

# 26. Thêm hoặc cập nhật icon cho `SkyPC.app` và DMG

Có 3 khái niệm icon khác nhau trên macOS:

1. **App icon** — icon của `SkyPC.app` trong Finder, Dock và Applications.
2. **Volume icon** — icon của volume `SkyPC` sau khi mount DMG.
3. **Icon của chính file `SkyPC.dmg` trong Finder** — đây là Finder metadata, không phải phần quan trọng của app signing/distribution và có thể bị mất khi upload/download. Với release production, nên ưu tiên app icon + volume icon.

Nếu `SkyPC.app` đã được ký/notarize mà bạn sửa `Info.plist`, thêm `.icns`, thay resource hoặc sửa bất kỳ file nào bên trong bundle, **signature cũ sẽ không còn hợp lệ**. Sau khi cập nhật icon phải ký lại app. Nếu artifact cuối cùng là DMG thì có thể ký app, tạo/ký DMG rồi notarize chính DMG; không bắt buộc notarize app riêng lần nữa.

## 26.1 Chuẩn bị icon nguồn

### Logo SkyPC hiện tại

Logo production hiện tại của SkyPC:

```text
https://theskypc.com/logo.png
```

Có thể tải thẳng về máy build/signing:

```bash
cd ~/SkyPC-Workspace/Mac-signing

curl -L \
  "https://theskypc.com/logo.png" \
  -o SkyPC-logo.png
```

Kiểm tra file tải về:

```bash
file SkyPC-logo.png
sips -g pixelWidth -g pixelHeight SkyPC-logo.png
```

Để tạo app icon, nên chuẩn hóa logo thành canvas vuông 1024×1024 trước. Nếu muốn giữ nguyên hình ảnh hiện tại, có thể resize trực tiếp:

```bash
sips -z 1024 1024 SkyPC-logo.png --out SkyPC-icon.png
```

> Lưu ý thiết kế: logo hiện tại có nền sáng/trắng. Nếu dùng trực tiếp làm `.icns`, Finder/Dock sẽ hiển thị phần nền đó như một phần của icon. Nếu muốn icon giống phong cách app macOS hơn, nên chuẩn bị một bản logo 1024×1024 có padding hợp lý và nền/bo góc được thiết kế riêng cho app icon. Quy trình signing/notarization không thay đổi.

Nên dùng PNG vuông 1024×1024, ví dụ:

```text
SkyPC-icon.png
1024 x 1024
```

Đặt file trong `~/SkyPC-Workspace/Mac-signing` rồi chạy:

```bash
cd ~/SkyPC-Workspace/Mac-signing

rm -rf SkyPC.iconset
mkdir SkyPC.iconset

sips -z 16 16       SkyPC-icon.png --out SkyPC.iconset/icon_16x16.png
sips -z 32 32       SkyPC-icon.png --out SkyPC.iconset/icon_16x16@2x.png

sips -z 32 32       SkyPC-icon.png --out SkyPC.iconset/icon_32x32.png
sips -z 64 64       SkyPC-icon.png --out SkyPC.iconset/icon_32x32@2x.png

sips -z 128 128     SkyPC-icon.png --out SkyPC.iconset/icon_128x128.png
sips -z 256 256     SkyPC-icon.png --out SkyPC.iconset/icon_128x128@2x.png

sips -z 256 256     SkyPC-icon.png --out SkyPC.iconset/icon_256x256.png
sips -z 512 512     SkyPC-icon.png --out SkyPC.iconset/icon_256x256@2x.png

sips -z 512 512     SkyPC-icon.png --out SkyPC.iconset/icon_512x512.png
sips -z 1024 1024   SkyPC-icon.png --out SkyPC.iconset/icon_512x512@2x.png
```

Tạo file `.icns`:

```bash
iconutil -c icns SkyPC.iconset -o SkyPC.icns
```

Kiểm tra:

```bash
file SkyPC.icns
```

## 26.2 Thêm icon vào `SkyPC.app`

Copy `.icns` vào Resources:

```bash
cp SkyPC.icns SkyPC.app/Contents/Resources/SkyPC.icns
```

Ghi `CFBundleIconFile` vào `Info.plist`:

```bash
/usr/libexec/PlistBuddy \
  -c "Delete :CFBundleIconFile" \
  SkyPC.app/Contents/Info.plist 2>/dev/null || true

/usr/libexec/PlistBuddy \
  -c "Add :CFBundleIconFile string SkyPC.icns" \
  SkyPC.app/Contents/Info.plist
```

Kiểm tra:

```bash
plutil -p SkyPC.app/Contents/Info.plist | grep Icon
```

Kết quả mong muốn:

```text
"CFBundleIconFile" => "SkyPC.icns"
```

Nếu Finder vẫn cache icon cũ:

```bash
killall Finder
```

## 26.3 Ký lại `SkyPC.app`

Vì bundle vừa bị thay đổi, phải ký lại:

```bash
xattr -cr SkyPC.app

codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "F0A8C68A074C696C9EECB33069FC797CC79B7C5A" \
  SkyPC.app
```

Verify:

```bash
codesign --verify \
  --deep \
  --strict \
  --verbose=4 \
  SkyPC.app
```

Mong muốn:

```text
SkyPC.app: valid on disk
SkyPC.app: satisfies its Designated Requirement
```

## 26.4 Tạo staging folder cho DMG

```bash
rm -rf dmg-root
mkdir dmg-root

ditto SkyPC.app dmg-root/SkyPC.app
ln -s /Applications dmg-root/Applications
```

Copy icon volume:

```bash
cp SkyPC.icns dmg-root/.VolumeIcon.icns
```

Cấu trúc staging:

```text
dmg-root/
├── .VolumeIcon.icns
├── SkyPC.app
└── Applications -> /Applications
```

## 26.5 Cách đáng tin cậy để đặt custom volume icon

Để custom volume icon ổn định, nên tạo một DMG read-write trước, mount nó, đặt custom-icon flag lên chính volume rồi mới convert sang DMG compressed read-only.

Tạo DMG tạm:

```bash
rm -f SkyPC-rw.dmg SkyPC.dmg

hdiutil create \
  -volname "SkyPC" \
  -srcfolder dmg-root \
  -ov \
  -format UDRW \
  SkyPC-rw.dmg
```

Mount:

```bash
hdiutil attach SkyPC-rw.dmg
```

Sau khi mount, volume thường ở:

```text
/Volumes/SkyPC
```

Đảm bảo `.VolumeIcon.icns` có trong root volume:

```bash
ls -la /Volumes/SkyPC
```

Tìm `SetFile`:

```bash
xcrun -f SetFile
```

Đặt custom-icon flag lên volume:

```bash
xcrun SetFile -a C /Volumes/SkyPC
```

Unmount:

```bash
hdiutil detach /Volumes/SkyPC
```

Convert sang DMG compressed read-only:

```bash
hdiutil convert \
  SkyPC-rw.dmg \
  -format UDZO \
  -o SkyPC.dmg
```

Xóa DMG tạm:

```bash
rm -f SkyPC-rw.dmg
```

> Nếu macOS cảnh báo một số cú pháp `hdiutil` cũ bị deprecated nhưng vẫn tạo được image thì đó chỉ là warning. Có thể chuyển sang `diskutil image ...` ở pipeline mới sau này; không cần thay đổi artifact đang chạy ổn giữa chừng.

## 26.6 Kiểm tra icon trước khi ký DMG

Mount thử:

```bash
hdiutil attach SkyPC.dmg
open /Volumes/SkyPC
```

Kiểm tra:

- `SkyPC.app` có icon đúng.
- Volume `SkyPC` có custom icon.
- Shortcut `Applications` hoạt động.

Unmount:

```bash
hdiutil detach /Volumes/SkyPC
```

## 26.7 Ký DMG sau khi hoàn tất mọi thay đổi giao diện

Không chỉnh sửa DMG sau bước này.

```bash
codesign \
  --force \
  --timestamp \
  --sign "F0A8C68A074C696C9EECB33069FC797CC79B7C5A" \
  --identifier "com.sub2s.skypc.dmg" \
  SkyPC.dmg
```

Verify:

```bash
codesign --verify --verbose=4 SkyPC.dmg
```

## 26.8 Notarize lại DMG

Vì DMG mới khác artifact cũ, ticket notarization trước đó không áp dụng cho file mới.

```bash
xcrun notarytool submit \
  SkyPC.dmg \
  --keychain-profile "SkyPC-Notary" \
  --wait
```

Mục tiêu:

```text
status: Accepted
```

Sau đó staple:

```bash
xcrun stapler staple SkyPC.dmg
xcrun stapler validate SkyPC.dmg
```

Kiểm tra Gatekeeper:

```bash
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  SkyPC.dmg
```

## 26.9 Thứ tự đúng khi thay icon ở release production

```text
SkyPC-icon.png
    ↓
SkyPC.icns
    ↓
copy vào SkyPC.app/Contents/Resources
    ↓
update Info.plist
    ↓
re-sign SkyPC.app
    ↓
verify app
    ↓
create DMG staging
    ↓
add .VolumeIcon.icns
    ↓
create/mount temporary read-write DMG
    ↓
set custom volume icon flag
    ↓
convert to compressed read-only SkyPC.dmg
    ↓
sign SkyPC.dmg
    ↓
notarize SkyPC.dmg
    ↓
staple SkyPC.dmg
    ↓
Gatekeeper verify
```

**Không được** chỉnh sửa `SkyPC.app` sau khi ký, hoặc chỉnh sửa `SkyPC.dmg` sau khi ký. Nếu có thay đổi, phải ký lại artifact tương ứng và notarize lại artifact cuối cùng.

---

# Lệnh nhanh: end-to-end cho release tiếp theo

Giả sử:

```text
Binary:      ~/SkyPC-Workspace/Mac-signing/skypc
App:         ~/SkyPC-Workspace/Mac-signing/SkyPC.app
DMG:         ~/SkyPC-Workspace/Mac-signing/SkyPC.dmg
Bundle ID:   com.sub2s.skypc
Identity:    F0A8C68A074C696C9EECB33069FC797CC79B7C5A
Notary:      SkyPC-Notary
```

Sau khi `SkyPC.app` đã được tạo đầy đủ:

```bash
# Sign app
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "F0A8C68A074C696C9EECB33069FC797CC79B7C5A" \
  SkyPC.app

# Verify app
codesign --verify --deep --strict --verbose=4 SkyPC.app

# Create DMG staging
rm -rf dmg-root
mkdir dmg-root

ditto SkyPC.app dmg-root/SkyPC.app
ln -s /Applications dmg-root/Applications

# Create DMG
rm -f SkyPC.dmg
hdiutil create \
  -volname "SkyPC" \
  -srcfolder dmg-root \
  -ov \
  -format UDZO \
  SkyPC.dmg

# Sign DMG
codesign \
  --force \
  --timestamp \
  --sign "F0A8C68A074C696C9EECB33069FC797CC79B7C5A" \
  --identifier "com.sub2s.skypc.dmg" \
  SkyPC.dmg

# Verify DMG
codesign --verify --verbose=4 SkyPC.dmg

# Notarize DMG
xcrun notarytool submit \
  SkyPC.dmg \
  --keychain-profile "SkyPC-Notary" \
  --wait

# Staple DMG
xcrun stapler staple SkyPC.dmg
xcrun stapler validate SkyPC.dmg

# Gatekeeper check
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  SkyPC.dmg
```

---

# Bảo mật signing key

Developer ID private key là tài sản release quan trọng.

Nên:

- Backup certificate + private key ra `.p12` và lưu trong password manager/secret vault của công ty.
- Không commit `.p12`, app-specific password hoặc API key vào Git.
- Nếu đưa lên CI, dùng secret storage của CI.
- Có thể dùng temporary keychain trên CI runner.
- Tách quyền build và quyền release nếu team lớn.

---

# Kết luận

Với quy trình này, SkyPC được phát hành theo mô hình macOS direct distribution chuẩn:

```text
Developer ID signed
+ Hardened Runtime
+ Apple notarized
+ Stapled ticket
+ DMG distribution
```

Đây là hướng phù hợp cho SkyPC hiện tại vì app có streaming, input, USB/IOKit và chưa cần các giới hạn App Sandbox của Mac App Store.
