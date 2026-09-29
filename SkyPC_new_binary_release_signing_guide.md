# SkyPC macOS — Quy trình ký và phát hành mỗi khi có binary mới

Tài liệu này dùng cho **các release tiếp theo**, sau khi máy ký đã được thiết lập sẵn:

- Developer ID Application certificate + private key đã có trong Keychain.
- `security find-identity -v -p codesigning` nhìn thấy Developer ID của Sub2s.
- `SkyPC-Notary` đã được lưu bằng `notarytool store-credentials`.
- Đã có một `SkyPC.app` template đúng cấu trúc, có `Info.plist` và `SkyPC.icns`.

Không cần tạo lại CSR, certificate, `.p12` hay notary profile cho mỗi binary mới.

## Chạy tự động từ binary mới

**Đã được thay thế bởi [guide v2](./SkyPC_macOS_release_signing_guide_v2.md#chạy-tự-động-theo-v2).**
Script [`release_skypc.sh`](./release_skypc.sh) hiện dùng `template/Info.plist`,
dựng app mới với `cp -X`, kiểm tra xattr trước ký, staging bằng `ditto` sau ký
và xuất `dist/SkyPC.dmg` trong từng run root. Xem guide v2 để biết cấu hình
`.env`, cấu trúc đầu ra, icon/Spotlight và các gate test.

Các bước thủ công bên dưới được giữ làm lịch sử **v1**, không còn là flow
hiện hành. Đặc biệt, không dùng app cũ làm template theo bước 3 của tài liệu này.
[Canonical plan và evidence](../skypc-app/docs/todo/signing_plan.md#9-binary-to-dmg-release-automation-2026-09-22)
vẫn được duy trì trong cùng một tài liệu.

---

# 1. Thông tin cố định của pipeline

Signing identity:

```text
Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
```

Notary profile:

```text
SkyPC-Notary
```

Workspace ví dụ:

```text
~/SkyPC-Workspace/Mac-signing/
├── skypc                  # binary mới từ dev
├── SkyPC.app              # app bundle template
├── SkyPC.icns             # icon dùng cho app/volume DMG
└── ...
```

Trong `SkyPC.app`, executable chính phải nằm tại:

```text
SkyPC.app/Contents/MacOS/skypc
```

---

# 2. Vào workspace và kiểm tra binary mới

```bash
cd ~/SkyPC-Workspace/Mac-signing
```

Kiểm tra file:

```bash
file ./skypc
```

Với bản hiện tại, mong muốn kiểu:

```text
Mach-O 64-bit executable arm64
```

Đặt executable bit:

```bash
chmod 755 ./skypc
```

Nếu muốn backup app bundle hiện tại trước khi thay binary:

```bash
rm -rf ./SkyPC.app.backup
cp -R ./SkyPC.app ./SkyPC.app.backup
```

---

# 3. Thay binary cũ trong `SkyPC.app`

```bash
cp ./skypc ./SkyPC.app/Contents/MacOS/skypc
chmod 755 ./SkyPC.app/Contents/MacOS/skypc
```

Kiểm tra lại:

```bash
file ./SkyPC.app/Contents/MacOS/skypc
```

> Việc thay executable làm chữ ký cũ của `SkyPC.app` mất hiệu lực. Đây là bình thường; bước tiếp theo sẽ ký lại bundle.

---

# 4. Cập nhật version nếu cần

Ví dụ release `0.1.1`, build `2`:

```bash
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 0.1.1" \
  ./SkyPC.app/Contents/Info.plist
```

```bash
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion 2" \
  ./SkyPC.app/Contents/Info.plist
```

Kiểm tra:

```bash
plutil -p ./SkyPC.app/Contents/Info.plist
```

Nếu release không cần đổi version thì bỏ qua bước này.

---

# 5. Dọn metadata trước khi ký

Chỉ chạy bước này **trước** `codesign`:

```bash
xattr -cr ./SkyPC.app
```

Không chạy `xattr -cr` sau khi đã ký/notarize artifact production.

---

# 6. Ký `SkyPC.app`

```bash
codesign \
  --force \
  --options runtime \
  --timestamp \
  --sign "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)" \
  ./SkyPC.app
```

Ý nghĩa:

- `--force`: thay chữ ký cũ.
- `--options runtime`: bật Hardened Runtime.
- `--timestamp`: secure timestamp của Apple.
- `--sign`: Developer ID Application production.

---

# 7. Verify chữ ký app

```bash
codesign \
  --verify \
  --deep \
  --strict \
  --verbose=4 \
  ./SkyPC.app
```

Mong muốn:

```text
./SkyPC.app: valid on disk
./SkyPC.app: satisfies its Designated Requirement
```

Xem chi tiết identity:

```bash
codesign -dvvv ./SkyPC.app 2>&1
```

Nên thấy:

```text
Identifier=com.sub2s.skypc
Authority=Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=P4F9DNFZ68
Timestamp=...
flags=0x10000(runtime)
```

---

# 8. Chạy thử app trước khi đóng DMG

```bash
open ./SkyPC.app
```

Nên test nhanh các chức năng quan trọng:

- UI / launch.
- Streaming.
- Keyboard / mouse.
- Gamepad.
- USB detect / hotplug / redirect.
- Camera.
- Microphone.

Nếu app lỗi ở đây, dừng pipeline và sửa trước. Không có lý do notarize một build đang lỗi runtime.

---

# 9. Chuẩn bị staging folder cho DMG

Xóa staging cũ:

```bash
rm -rf ./dmg-root
mkdir ./dmg-root
```

Copy app đã ký:

```bash
ditto ./SkyPC.app ./dmg-root/SkyPC.app
```

Tạo shortcut Applications:

```bash
ln -s /Applications ./dmg-root/Applications
```

Kiểm tra:

```bash
ls -la ./dmg-root
```

Mong muốn:

```text
SkyPC.app
Applications -> /Applications
```

---

# 10. Tạo DMG dạng writable để gắn volume icon

Không tạo `UDZO` ngay, vì DMG compressed/read-only không cho sửa `.VolumeIcon.icns` hoặc custom-icon bit.

Xóa artifact cũ:

```bash
rm -f ./SkyPC-rw.dmg ./SkyPC.dmg
```

Tạo writable DMG:

```bash
hdiutil create \
  -volname "SkyPC" \
  -srcfolder ./dmg-root \
  -ov \
  -format UDRW \
  ./SkyPC-rw.dmg
```

> macOS mới có thể cảnh báo một số cú pháp `hdiutil` là deprecated. Nếu lệnh vẫn tạo DMG thành công thì đây chỉ là warning, không phải signing failure.

---

# 11. Mount writable DMG

Đảm bảo không còn volume SkyPC cũ đang mount:

```bash
hdiutil detach "/Volumes/SkyPC" 2>/dev/null || true
```

Mount và để macOS tự tạo mount point:

```bash
hdiutil attach \
  ./SkyPC-rw.dmg \
  -readwrite \
  -noverify \
  -noautoopen
```

Thường volume sẽ nằm tại:

```text
/Volumes/SkyPC
```

Kiểm tra:

```bash
ls -la "/Volumes/SkyPC"
```

> Không cần `sudo mkdir /Volumes/SkyPC-build`. Tự tạo mount point bằng root có thể dẫn tới `hdiutil: attach failed - Permission denied`.

---

# 12. Gắn custom volume icon

Copy icon:

```bash
cp ./SkyPC.icns "/Volumes/SkyPC/.VolumeIcon.icns"
```

Ẩn file icon khỏi Finder:

```bash
xcrun SetFile -a V "/Volumes/SkyPC/.VolumeIcon.icns"
```

Đánh dấu volume là có custom icon:

```bash
xcrun SetFile -a C "/Volumes/SkyPC"
```

Kiểm tra:

```bash
ls -la "/Volumes/SkyPC"
```

Nên thấy:

```text
.VolumeIcon.icns
SkyPC.app
Applications
```

Flush xuống disk:

```bash
sync
```

Unmount:

```bash
hdiutil detach "/Volumes/SkyPC"
```

Nếu `SetFile` báo `Write Permissions Error (-61)`, gần như chắc chắn bạn đang thao tác trên DMG read-only/UDZO thay vì `SkyPC-rw.dmg` dạng UDRW.

---

# 13. Convert sang DMG release compressed/read-only

```bash
hdiutil convert \
  ./SkyPC-rw.dmg \
  -format UDZO \
  -o ./SkyPC.dmg
```

Verify image:

```bash
hdiutil verify ./SkyPC.dmg
```

Nếu pass, xóa intermediate writable image:

```bash
rm ./SkyPC-rw.dmg
```

Lúc này artifact release candidate là:

```text
SkyPC.dmg
```

---

# 14. Ký `SkyPC.dmg`

```bash
codesign \
  --force \
  --timestamp \
  --sign "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)" \
  ./SkyPC.dmg
```

Verify:

```bash
codesign --verify --verbose=4 ./SkyPC.dmg
```

Xem signature:

```bash
codesign -dvvv ./SkyPC.dmg 2>&1
```

Nên có:

```text
Authority=Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=P4F9DNFZ68
Timestamp=...
```

---

# 15. Submit DMG lên Apple Notary Service

Vì artifact cuối cùng được phân phối là `SkyPC.dmg`, submit chính DMG:

```bash
xcrun notarytool submit \
  ./SkyPC.dmg \
  --keychain-profile "SkyPC-Notary" \
  --wait
```

Kết quả mong muốn:

```text
status: Accepted
```

Nếu thấy:

```text
status: Invalid
```

lấy `Submission ID` và xem log:

```bash
xcrun notarytool log \
  <SUBMISSION_ID> \
  --keychain-profile "SkyPC-Notary"
```

Không nên sửa artifact theo phỏng đoán trước khi đọc notarization log.

> Nếu artifact cuối cùng luôn là DMG thì không cần notarize `SkyPC.app` riêng một lần nữa; app phải được ký đúng, còn DMG outermost được submit notarization.

---

# 16. Staple notarization ticket vào DMG

Chỉ chạy sau khi `notarytool` trả `Accepted`:

```bash
xcrun stapler staple ./SkyPC.dmg
```

Validate:

```bash
xcrun stapler validate ./SkyPC.dmg
```

Mong muốn:

```text
The validate action worked!
```

---

# 17. Gatekeeper verify artifact cuối

Kiểm tra outer DMG:

```bash
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  ./SkyPC.dmg
```

Mount DMG:

```bash
hdiutil attach ./SkyPC.dmg
```

Kiểm tra app bên trong:

```bash
spctl \
  --assess \
  --type execute \
  --verbose=4 \
  "/Volumes/SkyPC/SkyPC.app"
```

Mong muốn:

```text
accepted
source=Notarized Developer ID
```

Unmount:

```bash
hdiutil detach "/Volumes/SkyPC"
```

---

# 18. Tạo SHA-256 cho release

```bash
shasum -a 256 ./SkyPC.dmg
```

Nên lưu checksum cùng release để có thể đối chiếu artifact sau này.

---

# 19. Checklist nhanh cho mỗi binary mới

```text
[ ] Binary mới đã copy vào SkyPC.app/Contents/MacOS/skypc
[ ] chmod 755 executable
[ ] Version/build đã cập nhật nếu cần
[ ] xattr -cr trước khi sign
[ ] codesign SkyPC.app với Hardened Runtime + timestamp
[ ] codesign --verify app pass
[ ] open SkyPC.app chạy tốt
[ ] dmg-root mới được tạo
[ ] SkyPC-rw.dmg UDRW được tạo
[ ] .VolumeIcon.icns + custom icon bit đã set
[ ] UDRW đã detach và convert sang UDZO
[ ] SkyPC.dmg đã codesign
[ ] codesign --verify DMG pass
[ ] notarytool trả Accepted
[ ] stapler validate pass
[ ] spctl DMG/app pass
[ ] SHA-256 đã tạo
```

---

# 20. Flow production rút gọn

```text
binary skypc mới
        ↓
SkyPC.app/Contents/MacOS/skypc
        ↓
xattr -cr SkyPC.app
        ↓
codesign SkyPC.app
        ↓
codesign --verify
        ↓
test app
        ↓
create UDRW DMG
        ↓
custom volume icon
        ↓
convert UDRW → UDZO
        ↓
codesign SkyPC.dmg
        ↓
notarytool submit SkyPC.dmg
        ↓
Accepted
        ↓
stapler staple
        ↓
spctl verify
        ↓
SHA-256
        ↓
RELEASE SkyPC.dmg
```

---

# 21. Những thứ KHÔNG phải làm lại cho mỗi release

Không cần lặp lại các bước sau nếu máy ký vẫn hoạt động bình thường:

- Tạo CSR.
- Tạo Developer ID Application certificate mới.
- Import lại `.p12`.
- Tạo lại App-Specific Password.
- Tạo lại `SkyPC-Notary` profile.
- Xin USB/DriverKit entitlement chỉ vì có binary mới.

Chỉ cần làm lại các phần trên khi certificate hết hạn/revoke, private key bị mất, máy mới chưa được setup, hoặc kiến trúc/capability của app thay đổi.

---

# 22. Khi nào pipeline này phải thay đổi

Pipeline trên giả định `SkyPC.app` chỉ có main executable hiện tại.

Nếu dev bắt đầu thêm các thành phần như:

- `.dylib` riêng.
- Framework.
- Helper executable.
- XPC Service.
- Login Item.
- System Extension / DriverKit extension.

thì phải chuyển sang quy trình **sign inside-out**: ký nested code trước, rồi mới ký `SkyPC.app` ngoài cùng.
