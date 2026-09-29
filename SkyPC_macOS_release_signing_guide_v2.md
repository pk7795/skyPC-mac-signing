# SkyPC macOS Signing & Release Guide

> Workspace chuẩn: `~/SkyPC-Workspace/Mac-signing`  
> Team ID: `P4F9DNFZ68`  
> Developer ID Application:  
> `Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)`  
> Notary profile: `SkyPC-Notary`

## Chạy tự động

### V3: ký riêng ARM hoặc dùng output từ `build_mac_artifact.sh all`

[`release_skypc_v3.sh`](./release_skypc_v3.sh) nối workflow trong README với
pipeline production. Chạy build script với `arm64` khi chỉ phát hành Apple
Silicon, hoặc với `all` khi phát hành cả hai kiến trúc. V3 dùng lại binary và
DMG ad-hoc tương ứng; nó không gọi Cargo hoặc đóng gói lại build artifact.
Script mount read-only từng DMG được yêu cầu, kiểm tra bundle ID/version, thin
architecture, ad-hoc signature và yêu cầu DMG không cũ hơn binary. Sau khi toàn
bộ artifact thuộc mode đã chọn qua preflight, v3 chuyển từng binary sang flow
legacy v2 để dựng lại bundle `com.sub2s.skypc`, ký, notarize và kiểm tra final
DMG riêng. Hash của mỗi DMG build được ghi vào `release-evidence.txt` dưới key
`source artifact`.

```bash
# Chỉ phát hành Apple Silicon; không build, kiểm tra hay ký Intel
cd /Users/khoakheu/SkyPC-workspace/skypc-app
./build_mac_artifact.sh arm64

cd ../Mac-signing
./release_skypc_v3.sh --from-build arm64 --build 13
```

Khi cần phát hành cả hai kiến trúc:

```bash
cd /Users/khoakheu/SkyPC-workspace/skypc-app
./build_mac_artifact.sh all

cd ../Mac-signing
./release_skypc_v3.sh --from-build all --build 13
```

Version luôn lấy từ `skypc-app/Cargo.toml`. V3 từ chối `--version`, thiếu
`--build`, SMAppService marker và `--launch-agent-plist`. Có thể dùng
`--from-build arm64` hoặc `--from-build x86_64` để chỉ ký một kiến trúc.
Với `--from-build arm64`, script chỉ yêu cầu binary và DMG Apple Silicon; file
Intel có thể không tồn tại.
`--prepare-only` vẫn preflight artifact nhưng dừng trước Developer ID và Apple.
Hai DMG do build script tạo là nguồn provenance ad-hoc, không phải file phát
hành. Nếu truyền `--output-dir` cùng `all`, v3 tạo hai thư mục con `arm64` và
`x86_64` để không ghi đè evidence.

Deployment target được cố định theo kiến trúc: Apple Silicon là macOS 11.0,
Intel là macOS 10.12. Bản Intel có Swift overlay sẽ bundle các dylib tương ứng
vào `SkyPC.app/Contents/Frameworks`; v3 kiểm tra minimum OS, RPATH và chuyển đúng
`--minimum-os` sang pipeline production trước khi ký nested dylib rồi ký app.

### Release legacy tạm thời

Luồng `SMAppService` trong `skypc-app/src/tray.rs` đang được giữ tại stash
`3ca90d6ac8ad7cf0396f02f2a622037141c323e4` vì Login Item có vấn đề. Source hiện
tại đã trở về implementation legacy ghi
`~/Library/LaunchAgents/com.skypc.client.plist`. Build lại binary từ trạng thái
này rồi dùng wrapper sau:

```bash
cd /Users/khoakheu/SkyPC-workspace/skypc-app
cargo build --release --locked --package skypc
cp target/release/skypc ../Mac-signing/skypc-0.9.38-legacy

cd ../Mac-signing
./release_skypc_v2.sh ./skypc-0.9.38-legacy --version 0.9.38 --build 13
```

[`release_skypc_v2.sh`](./release_skypc_v2.sh) không nhúng LaunchAgent
SMAppService và sẽ từ chối binary vẫn chứa marker của flow mới. Không dùng lại
package build 12; build tiếp theo phải tăng số build. Flow legacy có thể tiếp
tục hiển thị tên tổ chức ký trong Background Items; đây là rollback tạm thời để
ưu tiên hành vi login cũ trong lúc điều tra lỗi.

### Release có Login Item mới

Phần này được giữ làm lịch sử và chỉ dùng lại sau khi phục hồi stash, sửa lỗi và
test Login Item trên app đã cài. Với binary có luồng `SMAppService`, dùng entry
point riêng:

```bash
cd /Users/khoakheu/SkyPC-workspace/Mac-signing
./release_skypc_smappservice.sh ./skypc-0.9.38 --version 0.9.38 --build 11
```

Script này kiểm tra binary có implementation mới, nhúng
`Contents/Library/LaunchAgents/com.sub2s.skypc.login-agent.plist`, rồi chuyển
toàn bộ tùy chọn sang `release_skypc.sh`. Chạy `--prepare-only` trước khi ký nếu
muốn kiểm tra app bundle. Binary build 9 và các binary cũ sẽ bị từ chối để tránh
tái tạo Login Item mang tên tổ chức ký.

Sau khi cài vào `/Applications`, lần chạy đầu đăng ký LaunchAgent bằng
`SMAppService` và gỡ file legacy `~/Library/LaunchAgents/com.skypc.client.plist`.
Ứng dụng chạy từ thư mục build hoặc trực tiếp trong DMG không đăng ký Login Item.

Script: [`release_skypc.sh`](./release_skypc.sh). Đây là hướng dẫn vận hành hiện
hành; [guide cũ](./SkyPC_new_binary_release_signing_guide.md) được giữ để tra cứu
lịch sử. Thiết kế, quyết định và evidence nằm trong [canonical signing plan —
SIGN-MAC-07](../skypc-app/docs/todo/signing_plan.md#9-binary-to-dmg-release-automation-2026-09-22),
liên kết với [ledger](../skypc-app/docs/todo/todo.md).

```bash
cd /Users/khoakheu/SkyPC-workspace/Mac-signing
./release_skypc.sh ./skypc --version 0.1.1 --build 2
```

**Release hiện tại:** `skypc-0.9.38`, package build 12. Lệnh lịch sử đã dùng
trước khi CLI v3 chuyển sang `--from-build`:

```bash
./release_skypc_v3.sh --binary ../skypc-app/target/release/skypc --build 12 --skip-smoke-test
```

Đây là version của app bundle; script không sửa version được biên dịch bên trong
binary và không sửa `skypc-app/Cargo.toml`. Backup 0.9.26/build 3 và các build
0.9.27 cũ là evidence lịch sử; không đổi nhãn một binary cũ thành release mới.

Build 12 dùng binary legacy không có marker SMAppService. Luồng v3 đã đóng gói
artifact trung gian, đối chiếu executable trùng byte với input, rồi qua Developer
ID, Apple Accepted (submission `29911596-b1cb-4213-b3fe-207e967ac844`), staple,
Gatekeeper cho DMG/app, background/layout, app/volume icon và checksum. Runtime
được ghi là chưa xác minh do dùng `--skip-smoke-test`. Đây là artifact lịch sử
của build 12, giữ nguyên tên cũ để bảo toàn evidence; các lần chạy mới dùng quy
ước `skypc_<version>-<build>_<arch>.dmg` ở phần trên:

```text
releases/SkyPC-0.9.38-12-20260924T162545Z.CLmWIv/dist/SkyPC.dmg
SHA-256: cd326cb1a66c3567b2ceb9e8f04819005e709e6e425a179728b87e60202f28d8
```

Binary là đầu vào bắt buộc duy nhất. Bỏ `--version`/`--build` sẽ dùng giá trị
trong **`template/Info.plist`**, không còn đọc plist từ app cũ. Script dựng mới
app, dùng `cp -X` cho binary/icon/plist, dọn xattr trước ký, ký rồi mở app để test.
Thoát app và nhập `PASS` sau khi kiểm tra các chức năng ở bước 12. Sau đó script
copy app đã ký bằng `ditto` vào staging, verify lại chữ ký và so sánh nội dung
trước khi tạo DMG. Không dọn xattr của app sau khi ký.

Để giữ các release trước và tránh hai lần chạy đụng nhau, script áp dụng cấu
trúc **build/dist của v2 bên trong một run root mới**:

```text
Mac-signing/releases/SkyPC-<version>-<build>-<UTC timestamp>.<random>/
├── build/
│   ├── SkyPC.app
│   ├── dmg-root/SkyPC.app
│   ├── SkyPC-rw.dmg
│   └── ... intermediate/candidate nếu thất bại
├── dist/
│   ├── skypc_<version>-<build>_<arch>.dmg
│   └── skypc_<version>-<build>_<arch>.dmg.sha256
├── release-evidence.txt
├── attach-*.plist
└── *.log, notary-result.plist
```

Thêm `--output-dir /path/to/new-run` để chọn run root; thư mục phải chưa tồn tại.
Đầu ra khi đó là `/path/to/new-run/dist/skypc_<version>-<build>_<arch>.dmg`.
`<arch>` là `arm64` hoặc `x86_64` khi chạy v3 theo từng kiến trúc; flow trực
tiếp nhận binary universal sẽ dùng `universal`. Cách đặt tên này tương ứng với
Ubuntu (`skypc_<version>-<revision>_<arch>.deb`) và áp dụng giống nhau cho
DMG cùng file checksum. Script không ghi đè
`Mac-signing/build/` hoặc `Mac-signing/dist/` dùng cho thao tác thủ công bên dưới.
So với script v1, DMG/checksum chuyển từ ngay run root xuống `dist/`.
Chỉ phân phối DMG và checksum sau khi các bước tự động thành công:

```bash
cd /path/to/new-run/dist
shasum -a 256 -c skypc_<version>-<build>_<arch>.dmg.sha256
```

Script để macOS chọn mountpoint, đọc **device và mountpoint thực tế** từ
`hdiutil attach -plist`, rồi detach đúng device của lần chạy đó. Không mặc định
`/Volumes/SkyPC`: nếu đã có volume trùng tên, macOS có thể chọn tên khác. Các
ví dụ thủ công dưới đây dùng `/Volumes/SkyPC`; luôn thay bằng mountpoint thực
tế vừa được `hdiutil` trả về trước khi copy icon, verify hoặc detach.

### Cấu hình Apple và các tùy chọn

Giữ `.env` đã cấu hình. Chỉ trên máy chưa có file mới chạy:

```bash
./release_skypc.sh --init-env
```

- `.env` có quyền `600` hoặc `400`, thuộc user chạy script. `NOTARY_AUTH=apple-id`
  dùng `APPLE_ID`, `APPLE_APP_SPECIFIC_PASSWORD`, `APPLE_TEAM_ID`; password phải
  là **app-specific password**, không phải mật khẩu đăng nhập Apple thông thường.
- `NOTARY_AUTH=keychain` và `NOTARY_PROFILE=SkyPC-Notary` dùng profile đã lưu,
  không cần tạo lại profile mỗi release.
- `--prompt-password` hỏi password bằng input ẩn; `--env FILE` chọn file khác.
- `.env` chỉ hỗ trợ `KEY=value` literal và dấu nháy bao ngoài; không `export`,
  nội suy biến, lệnh shell, giá trị nhiều dòng hoặc comment cuối dòng.
- Script không in password/copy `.env` vào artifact. Chế độ Apple ID truyền
  password qua đối số `notarytool`; Keychain tránh việc password xuất hiện trong
  đối số tiến trình. Không commit `.env` hoặc private key.
- `--icon FILE.icns`, `--plist FILE`, `--entitlements FILE` chọn asset/plist đã
  review. `--plist` chỉ đọc metadata, không copy code/resource từ một app cũ.
  Mặc định dùng `template/SkyPC.entitlements` với quyền camera và audio-input;
  file override cũng bắt buộc giữ hai quyền này. Pipeline không bật App Sandbox.
- `--skip-smoke-test` dành cho kiểm thử tự động hoặc lượt chạy không tương tác;
  evidence ghi runtime **unverified**, không đáp ứng gate test release ở bước 12.

Mỗi lỗi dừng pipeline và giữ evidence; chỉ Apple trả `Accepted` mới được staple.
Sau staple, verify DMG và app bên trong bằng Gatekeeper, kiểm tra lại icon,
metadata, executable; checksum được kiểm tra trước khi đặt tên cuối trong `dist/`.
Không phân phối intermediate/candidate. Chưa có resume tự động: sửa lỗi rồi chạy
lại vào run root mới. Staging/intermediate được giữ để debug và cần vài lần dung
lượng binary. Không tự cài app hoặc thực hiện test người dùng ở bước 21.

### Nền cửa sổ DMG, logo, Spotlight và kiểm tra cục bộ

Mặc định script dùng **`../skypc-app/assets/AppIcon.icns`** làm icon và
**`../skypc-app/assets/background.jpg`** làm nền cửa sổ Finder. Ghi đè bằng
`--icon FILE.icns` hoặc `--background FILE`. Nền được đóng tại
`.background/background.tiff` trong DMG, giữ 1800×702 pixel gốc và đặt **144 DPI**
cho kích thước hiển thị **900×351 point**. Không sửa asset gốc. Trước đóng gói
và sau khi mount DMG cuối, script đọc lại pixel/DPI để kiểm tra kích thước hiển thị
thực khớp canvas; không chỉ dựa vào exit code của lệnh đặt DPI.

**Sửa lỗi density ngày 2026-09-22:** JPEG của các lượt 0.9.26/3 và 0.9.27/4 vẫn đọc ra
72 DPI dù `sips` đặt 144 DPI báo thành công; AppKit vì thế đọc nền thành
1800×702 point. Bản sửa chuyển sang TIFF, đã xác nhận native AppKit đọc đúng
900×351 trên image thử.

**Sửa lỗi Finder background ngày 2026-09-22:** 0.9.27 build 5 có TIFF đúng kích thước và
`.DS_Store` đọc được bằng parser, nhưng Finder thực tế vẫn không hiển thị nền.
Metadata tự tạo không có bookmark `pBBk`/`pBB0`, nên các kiểm tra alias/inode cũ
là false positive. Flow hiện tại dùng [`finder_layout.applescript`](./finder_layout.applescript)
để Finder ghi layout trên writable image, rồi [`dmg_layout.py`](./dmg_layout.py)
bắt buộc kiểm tra bookmark do Finder tạo, alias, inode, kích thước ảnh, cửa sổ và
tọa độ icon cả trước lẫn sau khi convert sang DMG read-only. Nếu Finder/Automation
không hoạt động, pipeline dừng trước ký DMG và trước Apple notarization.

**Sửa lỗi chọn nhầm cửa sổ Finder ngày 2026-09-24:** Finder có thể chưa đưa
cửa sổ volume vừa mở lên trước khi AppleScript chạy lệnh tiếp theo. Dùng `front
window` khi đó có thể trỏ vào một cửa sổ khác và báo không đặt được vị trí
`SkyPC.app`. Flow hiện tại lấy `container window` trực tiếp từ folder của mount
path và chờ có giới hạn khi Finder nạp item. Kiểm tra trên bản sao UDRW thật phải
qua bookmark background và vị trí hai icon trước khi chạy production.

**Sửa lỗi volume icon ngày 2026-09-22:** build 6 xác nhận background Finder hợp
lệ, nhưng Finder đã xóa `.VolumeIcon.icns` và custom-icon flag vì icon được áp
trước khi Finder lưu layout. Script nay áp logo volume **sau** bước Finder, rồi
kiểm tra file/flags ngay trước detach và kiểm tra lại trên DMG cuối. Build 6 đã
Apple Accepted/stapled nhưng không có logo volume, nên giữ làm evidence và không
phân phối. Build 7 dùng thứ tự mới, qua toàn bộ gate tự động và ảnh kiểm tra Finder
cho thấy background mây cùng hai icon đúng vị trí. Không sửa trực tiếp DMG đã ký.

Finder hiển thị picture background ở kích thước cố định; nó không có chế độ CSS
`cover`/`repeat` khi người dùng phóng cửa sổ. Vì vậy background 900×351 point của
build 7 sẽ lộ màu trắng ngoài mép nếu cửa sổ lớn hơn. Có thể đóng gói một canvas
TIFF lớn được ghép sẵn bằng [`background_tile.swift`](./background_tile.swift),
nhưng đây vẫn là ảnh hữu hạn và hình lặp có thể lộ đường nối. Build 7 không tự
nhận thay đổi này; nếu chọn tiled background thì phải dùng build mới và chạy lại
toàn bộ signing/notarization.

Cài thư viện bố cục một lần (workspace này đã cài trong `.venv`):

```bash
python3 -m venv .venv
.venv/bin/python -m pip install -r dmg-layout-requirements.txt
```

Script mở Finder trong phiên GUI hiện tại qua AppleScript để tạo `.DS_Store` và
bookmark background chính chủ Finder: icon view, ẩn toolbar/sidebar/statusbar,
icon 96 px, SkyPC bên trái và Applications bên phải. macOS có thể yêu cầu cấp
quyền Automation cho Terminal/caller điều khiển Finder. `dmg_layout.py` với
`ds-store`/`mac-alias` được pin chỉ đọc và xác minh metadata sau đó. Có thể đặt
`SKYPC_LAYOUT_PYTHON=/path/to/venv/bin/python3` để dùng venv khác đã cài
dependencies. Tải dependency chỉ ở bước setup, không trong mỗi release.

Ảnh, alias tới file trong volume, kích thước cửa sổ và tọa độ icon đều phải qua
kiểm tra lại trên DMG read-only sau nén. Lỗi layout dừng pipeline, không xuất file
release cuối. `INSTALL.txt` ở cạnh DMG trong `dist/`, không hiện như icon thứ ba
trong cửa sổ cài đặt. Tham khảo [ds_store](https://ds-store.readthedocs.io/en/latest/)
và [dmgbuild](https://github.com/dmgbuild/dmgbuild) cho định dạng bố cục Finder.

Các bước thủ công dưới đây giữ phương pháp volume icon của guide v2; để có nền
và bố cục đầy đủ, dùng script tự động. Getter AppleScript của background vẫn trả
`-10000` trên macOS 27 ngay cả với nền hợp lệ, nên flow không dùng getter đó;
bookmark `pBBk`/`pBB0` do Finder ghi là gate máy đọc được.

Script yêu cầu ICNS đủ 10 representation (16/32/128/256/512 px và `@2x`, gồm
1024 px). Bundle có tên `SkyPC`, ID `com.sub2s.skypc`, `CFBundleIconFile`, package
type `APPL`, không ẩn Dock/background-only. DMG có logo volume, hidden/custom-icon
flags, shortcut Applications; tất cả được kiểm tra lại sau nén. Copy volume icon
cũng dùng `cp -X` để tránh mang metadata tải xuống vào image. Thứ tự bắt buộc là
Finder lưu/verify background trước, sau đó mới copy icon và đặt flags.

Sau bước 21, kiểm tra logo trong Finder/Dock và tìm **SkyPC** bằng **⌘Space**.
Spotlight phụ thuộc việc index trên máy nhận; script không reset cache hoặc sửa
Search Privacy. Có thể kiểm tra thêm:

```bash
mdls -name kMDItemDisplayName -name kMDItemCFBundleIdentifier /Applications/SkyPC.app
mdfind 'kMDItemCFBundleIdentifier == "com.sub2s.skypc"'
./release_skypc.sh ./skypc --prepare-only --output-dir /tmp/skypc-v2-prepare-new
python3 tests/test_release_skypc.py
```

`--prepare-only` dừng tại `build/SkyPC.app` đã dựng/dọn metadata, chưa ký, chưa
staging, không gọi Apple hoặc tạo DMG release. Test suite dùng file/plist/icon/
xattr/ditto thật, mô phỏng signing/notary/disk để kiểm tra flow và các nhánh lỗi.
Kết quả đó không thay thế Developer ID/notarization và test cài đặt thực tế.

---

## 1. Mục tiêu

Tài liệu này mô tả workflow chuẩn để đi từ một binary macOS mới của SkyPC đến file release:

```text
binary skypc mới
    ↓
build SkyPC.app mới hoàn toàn
    ↓
clean extended attributes / quarantine
    ↓
codesign SkyPC.app
    ↓
test app
    ↓
build DMG writable
    ↓
Finder lưu background và layout
    ↓
gắn custom volume icon sau Finder
    ↓
convert sang DMG release
    ↓
codesign DMG
    ↓
Apple notarization
    ↓
staple ticket
    ↓
Gatekeeper verify
    ↓
SHA-256
    ↓
RELEASE
```

Không tái sử dụng trực tiếp một `SkyPC.app` cũ đã notarize/staple/download qua browser làm source cho release mới.

---

# 2. Cấu trúc workspace chuẩn

Workspace:

```bash
cd ~/SkyPC-Workspace/Mac-signing
```

Khuyến nghị cấu trúc:

```text
~/SkyPC-Workspace/Mac-signing/
├── skypc                       # binary mới từ dev
├── skypc.unsigned-backup       # binary backup nếu cần
├── SkyPC.icns                  # app/volume icon
│
├── template/
│   └── Info.plist              # Info.plist sạch
│
├── build/
│   ├── SkyPC.app               # app generate mới mỗi release
│   ├── dmg-root/
│   └── SkyPC-rw.dmg
│
└── dist/
    └── SkyPC.dmg               # artifact release cuối
```

Tạo các thư mục nếu chưa có:

```bash
cd ~/SkyPC-Workspace/Mac-signing

mkdir -p template
mkdir -p build
mkdir -p dist
```

---

# 3. Kiểm tra signing identity

Chỉ cần làm khi setup máy mới hoặc nghi ngờ Keychain có vấn đề.

```bash
security find-identity -v -p codesigning
```

Phải có:

```text
Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
```

Có thể kiểm tra notary profile:

```bash
xcrun notarytool history \
  --keychain-profile "SkyPC-Notary"
```

Nếu command chạy được thì profile notarization hoạt động.

---

# 4. Chọn binary sẽ release

Nếu dev vừa gửi binary mới tên:

```text
skypc
```

thì dùng file đó.

Kiểm tra:

```bash
cd ~/SkyPC-Workspace/Mac-signing

ls -lh ./skypc
file ./skypc
```

Kỳ vọng:

```text
Mach-O 64-bit executable arm64
```

Set executable bit:

```bash
chmod 755 ./skypc
```

> `skypc.unsigned-backup` chỉ dùng khi đó chính là binary bạn muốn release.  
> Không mặc định dùng backup nếu dev đã gửi build mới hơn.

---

# 5. Tạo Info.plist sạch

Nếu `template/Info.plist` chưa tồn tại, tạo mới:

```bash
cat > ./template/Info.plist <<'EOF'
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

    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeRole</key>
            <string>Viewer</string>
            <key>CFBundleURLName</key>
            <string>com.sub2s.skypc.oidc</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>skypc</string>
            </array>
        </dict>
    </array>

    <key>CFBundleShortVersionString</key>
    <string>0.1.1</string>

    <key>CFBundleVersion</key>
    <string>2</string>

    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>

    <key>NSHighResolutionCapable</key>
    <true/>

    <key>CFBundleIconFile</key>
    <string>SkyPC.icns</string>

    <key>NSCameraUsageDescription</key>
    <string>SkyPC requires camera access for remote camera functionality.</string>

    <key>NSMicrophoneUsageDescription</key>
    <string>SkyPC requires microphone access for remote audio functionality.</string>

    <key>NSLocalNetworkUsageDescription</key>
    <string>SkyPC uses the local network to connect to computers you choose for remote desktop and game streaming.</string>

</dict>
</plist>
EOF
```

Kiểm tra:

```bash
plutil -lint ./template/Info.plist
```

Kỳ vọng:

```text
./template/Info.plist: OK
```

---

# 6. Cập nhật version cho release

Ví dụ release:

```text
Version: 0.1.1
Build:   2
```

Sửa template:

```bash
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleShortVersionString 0.1.1" \
  ./template/Info.plist
```

```bash
/usr/libexec/PlistBuddy \
  -c "Set :CFBundleVersion 2" \
  ./template/Info.plist
```

Kiểm tra:

```bash
plutil -p ./template/Info.plist | \
grep -E 'CFBundleIdentifier|CFBundleIconFile|CFBundleShortVersionString|CFBundleVersion'
```

Kỳ vọng dạng:

```text
"CFBundleIdentifier" => "com.sub2s.skypc"
"CFBundleIconFile" => "SkyPC.icns"
"CFBundleShortVersionString" => "0.1.1"
"CFBundleVersion" => "2"
```

---

# 7. Build SkyPC.app mới hoàn toàn

Không sửa trên `SkyPC.app` cũ.

Xóa build cũ:

```bash
rm -rf ./build/SkyPC.app
```

Tạo cấu trúc:

```bash
mkdir -p ./build/SkyPC.app/Contents/MacOS
mkdir -p ./build/SkyPC.app/Contents/Resources
```

Copy binary mới:

```bash
cp -X ./skypc \
  ./build/SkyPC.app/Contents/MacOS/skypc
```

Set executable:

```bash
chmod 755 ./build/SkyPC.app/Contents/MacOS/skypc
```

Copy icon:

```bash
cp -X ./SkyPC.icns \
  ./build/SkyPC.app/Contents/Resources/SkyPC.icns
```

Copy Info.plist:

```bash
cp -X ./template/Info.plist \
  ./build/SkyPC.app/Contents/Info.plist
```

---

# 8. QUAN TRỌNG: Clean quarantine và extended attributes

Binary hoặc icon tải qua Chrome có thể mang:

```text
com.apple.quarantine
com.apple.provenance
com.apple.macl
```

Kiểm tra:

```bash
xattr -lr ./build/SkyPC.app
```

Ví dụ đã từng gặp:

```text
./build/SkyPC.app/Contents/MacOS/skypc:
com.apple.quarantine: ...;Chrome;...

./build/SkyPC.app/Contents/Resources/SkyPC.icns:
com.apple.quarantine: ...;Chrome;...
```

### Clean đúng cách trước khi codesign

Xóa quarantine:

```bash
xattr -dr com.apple.quarantine ./build/SkyPC.app
```

Sau đó dọn toàn bộ extended attributes còn lại:

```bash
xattr -cr ./build/SkyPC.app
```

Kiểm tra lại:

```bash
xattr -lr ./build/SkyPC.app
```

### Kết quả lý tưởng

Command trên:

```bash
xattr -lr ./build/SkyPC.app
```

**không in gì cả**.

**Bổ sung từ kiểm thử script v2:** Trên máy macOS 27 hiện tại,
`com.apple.provenance` vẫn xuất hiện trên bundle mới dù `cp -X`, `xattr -cr` và
xóa trực tiếp attribute đều hoàn tất. Bundle thử với attribute này đã pass ký
ad-hoc và `codesign --verify --deep --strict`; đây không phải bằng chứng Apple
notarization. Vì vậy script ghi nhận riêng trường hợp chỉ còn provenance, nhưng
dừng trước ký nếu còn quarantine, FinderInfo, ResourceFork, macl hoặc attribute
khác. Không dùng việc `xattr -cr` trả exit 0 làm bằng chứng metadata đã sạch.
Evidence chỉ lưu tên/trạng thái attribute, không lưu giá trị metadata tải xuống.

> Đây là thời điểm đúng để chạy `xattr`.  
> Sau khi đã codesign thì không chạy `xattr -cr` bừa lên app nữa.

---

# 9. Kiểm tra bundle trước khi ký

Kiểm tra Info.plist:

```bash
plutil -lint ./build/SkyPC.app/Contents/Info.plist
```

Kiểm tra binary:

```bash
file ./build/SkyPC.app/Contents/MacOS/skypc
```

Kiểm tra icon:

```bash
ls -lh ./build/SkyPC.app/Contents/Resources/SkyPC.icns
```

Kiểm tra version:

```bash
plutil -p ./build/SkyPC.app/Contents/Info.plist | \
grep -E 'CFBundleIdentifier|CFBundleShortVersionString|CFBundleVersion|CFBundleIconFile'
```

---

# 10. Sign SkyPC.app

Chạy:

```bash
codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements ./template/SkyPC.entitlements \
  --sign "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)" \
  ./build/SkyPC.app
```

`--options runtime` bật Hardened Runtime.

`--entitlements` cấp quyền camera và audio-input cho Hardened Runtime. Chỉ có
`NSCameraUsageDescription`/`NSMicrophoneUsageDescription` trong Info.plist là
chưa đủ cho bản production đã bật Hardened Runtime.

`--timestamp` lấy secure timestamp của Apple.

---

# 11. Verify app signature

```bash
codesign \
  --verify \
  --deep \
  --strict \
  --verbose=4 \
  ./build/SkyPC.app
```

Kỳ vọng:

```text
./build/SkyPC.app: valid on disk
./build/SkyPC.app: satisfies its Designated Requirement
```

Xem chi tiết:

```bash
codesign -dvvv ./build/SkyPC.app 2>&1
codesign -d --entitlements :- ./build/SkyPC.app \
  > ./build/SkyPC.signed-entitlements.plist
plutil -lint ./build/SkyPC.signed-entitlements.plist
plutil -extract 'com\.apple\.security\.device\.camera' raw -o - \
  ./build/SkyPC.signed-entitlements.plist
plutil -extract 'com\.apple\.security\.device\.audio-input' raw -o - \
  ./build/SkyPC.signed-entitlements.plist
```

Hai lệnh `plutil -extract` đều phải in `true`. Dùng đúng `:-` để `codesign`
xuất XML plist; trên bản `codesign` hiện tại, `--entitlements -` có thể xuất
dạng mô tả `[Dict]` mà `plutil` không đọc được.

Kiểm tra các dòng:

```text
Identifier=com.sub2s.skypc
Authority=Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
TeamIdentifier=P4F9DNFZ68
Timestamp=...
flags=0x10000(runtime)
```

---

# 12. Test app trước khi làm DMG

```bash
open ./build/SkyPC.app
```

Nếu Camera vẫn chỉ có `Tắt`, không xác nhận `PASS`. macOS có thể đang giữ trạng
thái `Denied` trước đó cho `com.sub2s.skypc`; bật SkyPC trong **System Settings >
Privacy & Security > Camera**, thoát app rồi mở lại. Không tự động reset TCC trong
release script vì thao tác đó thay đổi lựa chọn quyền riêng tư của người dùng.

Test các chức năng quan trọng:

```text
- UI
- Google SSO hoàn tất trong browser và callback `skypc://oidc-complete` quay lại đúng SkyPC
- Local Network/direct streaming
- Accessibility keyboard/mouse grab
- wired/Bluetooth gamepad input and output/rumble
- USB list, bind/redirect, hotplug and reconnect with a real device
- camera selection and actual capture
- microphone selection and actual capture
```

Nếu app lỗi ở đây thì dừng. Không notarize một build chưa test.

## 12.1 Ma trận quyền và capability macOS

Luồng Developer ID hiện tại **không bật App Sandbox**. Vì vậy không thêm các
entitlement `com.apple.security.network.*`, `com.apple.security.device.usb` hay
`com.apple.security.device.bluetooth`: Apple định nghĩa các key này cho App
Sandbox và chúng không cấp thêm quyền cho bundle không sandbox. Entitlement ký
production chỉ giữ hai quyền resource access mà Hardened Runtime cần cho Camera
và audio input.

| Chức năng | Khai báo/signing hiện tại | Gate bắt buộc trên chính bản ký |
|---|---|---|
| Camera | `NSCameraUsageDescription` + `com.apple.security.device.camera` | Có prompt/trạng thái Camera hợp lệ, thấy thiết bị và capture frame thực tế |
| Microphone | `NSMicrophoneUsageDescription` + `com.apple.security.device.audio-input` | Có prompt/trạng thái Microphone hợp lệ, thấy thiết bị và capture audio thực tế; chỉ enumerate list chưa đủ |
| Local Network/streaming | `NSLocalNetworkUsageDescription`; không có sandbox network entitlement | Trên macOS 15+, xử lý prompt Local Network và kết nối/stream trực tiếp tới máy trong LAN |
| Keyboard/mouse control | Người dùng cấp Accessibility; app kiểm tra bằng AX API trước khi tạo `CGEventTap` | Bật SkyPC trong Privacy & Security > Accessibility, rồi kiểm tra capture/grab và input thực tế |
| USB passthrough | IOKit/nusb trong app không sandbox; không dùng USB/DriverKit/Accessory Access entitlement | List thiết bị, bind/seize interface, redirect dữ liệu, hotplug/reconnect; thử thiết bị đang có kernel driver vì bước seize có thể thất bại. Dependency hiện ghi physical forwarding trên macOS cần `sudo`, trong khi app chưa có privileged helper/elevation, nên đây là release risk đang mở |
| Gamepad | GameController + IOHID; không dùng CoreBluetooth entitlement | Thử tay cầm có dây và Bluetooth, input cùng output/rumble nếu thiết bị hỗ trợ |
| Clipboard | NSPasteboard cho text; không có entitlement riêng trong flow hiện tại | Copy/paste hai chiều trong phiên thực tế |
| Screen Recording | Binary hiện tại nhận và decode video từ máy remote, không dùng ScreenCaptureKit để chụp màn hình local | Không yêu cầu Screen Recording; audit lại nếu sau này thêm capture màn hình local |

Nếu kiến trúc chuyển sang App Sandbox, DriverKit/System Extension, Accessory
Access hoặc thêm capture màn hình local, phải review lại entitlement, provisioning
và UX cấp quyền trước release. Không suy ra quyền runtime chỉ từ việc notarization
được Apple chấp nhận.

---

# 13. Chuẩn bị staging cho DMG

Xóa staging cũ:

```bash
rm -rf ./build/dmg-root
mkdir -p ./build/dmg-root
```

Copy app:

```bash
ditto ./build/SkyPC.app \
  ./build/dmg-root/SkyPC.app
```

Tạo shortcut Applications:

```bash
ln -s /Applications ./build/dmg-root/Applications
```

Kiểm tra:

```bash
ls -la ./build/dmg-root
```

Phải có:

```text
SkyPC.app
Applications -> /Applications
```

---

# 14. Tạo DMG writable

Ta dùng DMG writable trước vì cần gắn custom volume icon.

Xóa artifact cũ:

```bash
rm -f ./build/SkyPC-rw.dmg
rm -f ./dist/SkyPC.dmg
```

Tạo UDRW:

```bash
hdiutil create \
  -volname "SkyPC" \
  -srcfolder ./build/dmg-root \
  -ov \
  -format UDRW \
  ./build/SkyPC-rw.dmg
```

Mount:

```bash
hdiutil attach \
  ./build/SkyPC-rw.dmg \
  -readwrite \
  -noverify \
  -noautoopen
```

Thông thường volume sẽ mount tại:

```text
/Volumes/SkyPC
```

Kiểm tra:

```bash
ls -la "/Volumes/SkyPC"
```

---

# 15. Gắn custom volume icon

Nếu cần background/layout, phải để Finder lưu và kiểm tra `.DS_Store` trước bước
này. Finder có thể xóa `.VolumeIcon.icns` và custom-icon flag trong lúc cập nhật
cửa sổ volume. Script tự động đã áp dụng đúng thứ tự này.

Copy icon:

```bash
cp ./SkyPC.icns \
  "/Volumes/SkyPC/.VolumeIcon.icns"
```

Ẩn file icon:

```bash
xcrun SetFile \
  -a V \
  "/Volumes/SkyPC/.VolumeIcon.icns"
```

Đánh dấu volume có custom icon:

```bash
xcrun SetFile \
  -a C \
  "/Volumes/SkyPC"
```

Kiểm tra:

```bash
ls -la "/Volumes/SkyPC"
```

Phải có:

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

> Không tự `sudo mkdir /Volumes/SkyPC-build` rồi ép mountpoint nếu không cần.  
> Trước đây cách đó đã gây `hdiutil: attach failed - Permission denied`.

---

# 16. Convert thành DMG release

```bash
hdiutil convert \
  ./build/SkyPC-rw.dmg \
  -format UDZO \
  -o ./dist/SkyPC.dmg
```

Kiểm tra:

```bash
hdiutil verify ./dist/SkyPC.dmg
```

Nếu pass:

```bash
rm ./build/SkyPC-rw.dmg
```

Artifact lúc này:

```text
~/SkyPC-Workspace/Mac-signing/dist/SkyPC.dmg
```

---

# 17. Sign DMG

```bash
codesign \
  --force \
  --timestamp \
  --sign "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)" \
  ./dist/SkyPC.dmg
```

Verify:

```bash
codesign --verify --verbose=4 ./dist/SkyPC.dmg
```

Xem chi tiết:

```bash
codesign -dvvv ./dist/SkyPC.dmg 2>&1
```

Kiểm tra:

```text
Authority=Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)
TeamIdentifier=P4F9DNFZ68
Timestamp=...
```

---

# 18. Submit notarization

Không cần notarize `SkyPC.app` riêng nếu artifact release cuối cùng luôn là DMG.

Submit:

```bash
xcrun notarytool submit \
  ./dist/SkyPC.dmg \
  --keychain-profile "SkyPC-Notary" \
  --wait
```

Kỳ vọng:

```text
status: Accepted
```

Nếu:

```text
status: Invalid
```

lấy submission ID và xem log:

```bash
xcrun notarytool log \
  <SUBMISSION_ID> \
  --keychain-profile "SkyPC-Notary"
```

---

# 19. Staple notarization ticket

Sau khi Apple trả:

```text
status: Accepted
```

chạy:

```bash
xcrun stapler staple ./dist/SkyPC.dmg
```

Validate:

```bash
xcrun stapler validate ./dist/SkyPC.dmg
```

Kỳ vọng:

```text
The validate action worked!
```

---

# 20. Gatekeeper verify

## Verify DMG

```bash
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  ./dist/SkyPC.dmg
```

## Mount DMG

```bash
hdiutil attach ./dist/SkyPC.dmg
```

## Verify app bên trong

```bash
spctl \
  --assess \
  --type execute \
  --verbose=4 \
  "/Volumes/SkyPC/SkyPC.app"
```

Kỳ vọng:

```text
accepted
source=Notarized Developer ID
```

Unmount:

```bash
hdiutil detach "/Volumes/SkyPC"
```

---

# 21. Test như người dùng thật

Mở DMG:

```bash
open ./dist/SkyPC.dmg
```

Kéo:

```text
SkyPC.app → Applications
```

Sau đó:

```bash
open /Applications/SkyPC.app
```

Nên test trên một máy khác nếu có thể.

---

# 22. Tạo SHA-256 cho release

```bash
shasum -a 256 ./dist/SkyPC.dmg
```

Có thể lưu ra file:

```bash
shasum -a 256 ./dist/SkyPC.dmg \
  > ./dist/SkyPC.dmg.sha256
```

Artifact release:

```text
dist/SkyPC.dmg
dist/SkyPC.dmg.sha256
```

---

# 23. Những việc KHÔNG cần làm lại mỗi release

Không cần lặp lại:

```text
- tạo CSR
- tạo Developer ID certificate mới
- import .p12 lại
- tạo Team ID
- tạo App-Specific Password mới
- store-credentials lại nếu SkyPC-Notary vẫn dùng được
```

Chỉ cần lặp:

```text
binary mới
→ build app mới
→ clean xattr
→ sign app
→ test
→ build DMG
→ sign DMG
→ notarize
→ staple
→ verify
→ release
```

---

# 24. Troubleshooting

## 24.1 `Operation not permitted` khi sửa Info.plist

Nếu một `SkyPC.app` cũ có:

```text
com.apple.macl
com.apple.provenance
com.apple.quarantine
```

và kể cả:

```bash
sudo chown
sudo chmod
sudo chmod -RN
```

vẫn báo:

```text
Operation not permitted
```

thì không cố sửa bundle đó nữa.

Dựng:

```text
build/SkyPC.app
```

mới hoàn toàn từ:

```text
binary mới
template/Info.plist
SkyPC.icns
```

---

## 24.2 `xattr -lr ./build/SkyPC.app` có quarantine

Ví dụ:

```text
com.apple.quarantine: ...;Chrome;...
```

Chạy trước khi signing:

```bash
xattr -dr com.apple.quarantine ./build/SkyPC.app
xattr -cr ./build/SkyPC.app
```

Kiểm tra:

```bash
xattr -lr ./build/SkyPC.app
```

Lý tưởng không có output.

---

## 24.3 `hdiutil attach failed - Permission denied`

Không tự tạo mountpoint bằng:

```bash
sudo mkdir /Volumes/SkyPC-build
```

Rồi mount bằng user thường.

Thay vào đó:

```bash
hdiutil attach \
  ./build/SkyPC-rw.dmg \
  -readwrite \
  -noverify \
  -noautoopen
```

để macOS tự mount `/Volumes/SkyPC`.

---

## 24.4 `Write Permissions Error (-61)` khi SetFile

Bạn đang sửa một DMG read-only (`UDZO`).

Custom volume icon phải làm trên:

```text
UDRW
```

Flow đúng:

```text
dmg-root
→ SkyPC-rw.dmg (UDRW)
→ mount
→ Finder lưu/verify background và layout
→ .VolumeIcon.icns
→ SetFile
→ detach
→ convert UDZO
```

---

## 24.5 Raw binary bị `spctl` báo:

```text
rejected (the code is valid but does not seem to be an app)
```

Đây là vì raw Mach-O không phải `.app` bundle.

Đánh giá Gatekeeper đúng cách trên:

```text
SkyPC.app
```

hoặc:

```text
SkyPC.dmg
```

---

# 25. Pipeline ngắn gọn cho mỗi release

```bash
cd ~/SkyPC-Workspace/Mac-signing
```

### Build app

```bash
rm -rf ./build/SkyPC.app

mkdir -p ./build/SkyPC.app/Contents/MacOS
mkdir -p ./build/SkyPC.app/Contents/Resources

cp -X ./skypc ./build/SkyPC.app/Contents/MacOS/skypc
chmod 755 ./build/SkyPC.app/Contents/MacOS/skypc

cp -X ./SkyPC.icns ./build/SkyPC.app/Contents/Resources/SkyPC.icns
cp -X ./template/Info.plist ./build/SkyPC.app/Contents/Info.plist
```

### Clean xattr

```bash
xattr -dr com.apple.quarantine ./build/SkyPC.app
xattr -cr ./build/SkyPC.app
xattr -lr ./build/SkyPC.app
```

### Sign app

```bash
codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements ./template/SkyPC.entitlements \
  --sign "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)" \
  ./build/SkyPC.app
```

### Verify app

```bash
codesign --verify --deep --strict --verbose=4 ./build/SkyPC.app
codesign -d --entitlements :- ./build/SkyPC.app \
  > ./build/SkyPC.signed-entitlements.plist
plutil -lint ./build/SkyPC.signed-entitlements.plist
```

### Test app

```bash
open ./build/SkyPC.app
```

### Build DMG staging

```bash
rm -rf ./build/dmg-root
mkdir -p ./build/dmg-root

ditto ./build/SkyPC.app ./build/dmg-root/SkyPC.app
ln -s /Applications ./build/dmg-root/Applications
```

### Create writable DMG

```bash
rm -f ./build/SkyPC-rw.dmg ./dist/SkyPC.dmg

hdiutil create \
  -volname "SkyPC" \
  -srcfolder ./build/dmg-root \
  -ov \
  -format UDRW \
  ./build/SkyPC-rw.dmg
```

### Mount

```bash
hdiutil attach \
  ./build/SkyPC-rw.dmg \
  -readwrite \
  -noverify \
  -noautoopen
```

### Volume icon

```bash
cp ./SkyPC.icns "/Volumes/SkyPC/.VolumeIcon.icns"

xcrun SetFile -a V "/Volumes/SkyPC/.VolumeIcon.icns"
xcrun SetFile -a C "/Volumes/SkyPC"

sync
hdiutil detach "/Volumes/SkyPC"
```

### Convert release DMG

```bash
hdiutil convert \
  ./build/SkyPC-rw.dmg \
  -format UDZO \
  -o ./dist/SkyPC.dmg
```

### Sign DMG

```bash
codesign \
  --force \
  --timestamp \
  --sign "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)" \
  ./dist/SkyPC.dmg
```

### Notarize

```bash
xcrun notarytool submit \
  ./dist/SkyPC.dmg \
  --keychain-profile "SkyPC-Notary" \
  --wait
```

### Staple

```bash
xcrun stapler staple ./dist/SkyPC.dmg
xcrun stapler validate ./dist/SkyPC.dmg
```

### Gatekeeper

```bash
spctl \
  --assess \
  --type open \
  --context context:primary-signature \
  --verbose=4 \
  ./dist/SkyPC.dmg
```

### SHA-256

```bash
shasum -a 256 ./dist/SkyPC.dmg \
  > ./dist/SkyPC.dmg.sha256
```

---

# 26. Quy tắc quan trọng

1. `build/SkyPC.app` phải được generate mới mỗi release.
2. Clean `xattr` trước `codesign`.
3. Sau khi `codesign`, không chỉnh sửa file bên trong app.
4. Nếu sửa `Info.plist`, binary hoặc icon thì phải sign lại.
5. Nếu rebuild DMG thì phải sign/notarize/staple DMG mới.
6. Không dùng App Sandbox trừ khi có yêu cầu cụ thể.
7. Không thêm USB/DriverKit entitlement nếu chưa có bằng chứng macOS yêu cầu.
8. Không thêm sandbox network/Bluetooth entitlement hoặc JIT/library-validation
   exception vào flow Developer ID hiện tại.
9. Không dùng raw `.app` cũ đã download/copy qua browser làm template.
10. `dist/SkyPC.dmg` là artifact cuối cùng để release.
11. Giữ Developer ID private key và `.p12` trong storage bảo mật.
