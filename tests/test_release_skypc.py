#!/usr/bin/env python3
"""Contract tests: real Bash/plist/icon/copy, simulated signing/Apple/disk services.

Run on macOS: python3 Mac-signing/tests/test_release_skypc.py
No Keychain access, app launch, network, real mounts or release artifacts.
"""
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
MOCK = r'''#!/usr/bin/env python3
import os, pathlib, plistlib, shutil, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
a = sys.argv[1:]
state = pathlib.Path(os.environ['MOCK_STATE'])
case = os.environ.get('MOCK_CASE', '')
# Never log auth values. Trace only the service and operation.
with (state / 'trace').open('a') as f:
    f.write(name + ' ' + (a[0] if a else '') + '\n')
if name == 'security':
    print('1) ABC "Developer ID Application: Sub2s Technology and Media Broadcasting Joint Stock Company (P4F9DNFZ68)"')
elif name == 'codesign':
    if case == 'sign-fail' and '--force' in a: sys.exit(8)
    if '-d' in a and '--entitlements' in a:
        assert a[a.index('--entitlements') + 1] == ':-'
        sys.stdout.buffer.write(plistlib.dumps({
            'com.apple.security.device.audio-input': True,
            'com.apple.security.device.camera': True,
        }))
        sys.exit(0)
    if '--force' in a and a[-1].endswith('.app'):
        entitlements = pathlib.Path(a[a.index('--entitlements') + 1])
        with entitlements.open('rb') as stream: signed_entitlements = plistlib.load(stream)
        assert signed_entitlements == {
            'com.apple.security.device.audio-input': True,
            'com.apple.security.device.camera': True,
        }
        bundle = pathlib.Path(a[-1])
        signature = bundle / 'Contents/_CodeSignature'
        signature.mkdir()
        (signature / 'CodeResources').write_text('simulated signature')
        subprocess.run(['/usr/bin/xattr', '-w', 'com.skypc.test.signed', 'preserve signed metadata', str(bundle)], check=True)
    if '--verify' in a and a[-1].endswith('.app'):
        assert (pathlib.Path(a[-1]) / 'Contents/_CodeSignature/CodeResources').exists()
        assert subprocess.check_output(['/usr/bin/xattr', '-p', 'com.skypc.test.signed', a[-1]]).strip() == b'preserve signed metadata'
    if '-dvvv' in a: print('TeamIdentifier=P4F9DNFZ68\nflags=0x10000(runtime)')
elif name == 'spctl':
    if case == 'assess-fail': sys.exit(9)
elif name == 'layout-python':
    if a[0] == '-c': sys.exit(0)
    action, mount = a[1], pathlib.Path(a[2])
    assert a[3:] == ['900', '351']
    assert (mount / '.background/background.tiff').is_file()
    if action == 'verify':
        if case == 'layout-verify-fail': sys.exit(16)
        assert (mount / '.DS_Store').is_file()
    else: raise AssertionError('Unexpected layout action')
elif name == 'osascript':
    mount = pathlib.Path(a[1])
    assert a[2:] == ['900', '351']
    if case == 'layout-fail': sys.exit(15)
    # Finder can clear a volume icon and its flag while persisting window state.
    # The release flow must therefore apply the volume icon after this call.
    (mount / '.VolumeIcon.icns').unlink(missing_ok=True)
    (mount / '.DS_Store').write_bytes(b'fixture Finder-confirmed layout')
elif name == 'otool':
    mode = os.environ.get('MOCK_OTOOL_MODE', 'non-system')
    if mode == 'swift-system':
        if '-L' in a:
            print('binary:\n\t@rpath/libswiftCoreMedia.dylib (compatibility version 1)')
        else:
            print('Load command 1\n          cmd LC_RPATH\n      cmdsize 32\n         path /usr/lib/swift (offset 12)')
    elif mode == 'swift-local':
        if '-L' in a:
            print('binary:\n\t@rpath/libswiftCoreMedia.dylib (compatibility version 1)')
        else:
            print('Load command 1\n          cmd LC_RPATH\n      cmdsize 32\n         path @executable_path/../Frameworks (offset 12)\nLoad command 2\n          cmd LC_RPATH\n      cmdsize 32\n         path /usr/lib/swift (offset 12)')
    elif mode == 'swift-unsafe':
        if '-L' in a:
            print('binary:\n\t@rpath/libswiftCoreMedia.dylib (compatibility version 1)')
        else:
            print('Load command 1\n          cmd LC_RPATH\n      cmdsize 32\n         path /tmp/unreviewed-swift (offset 12)')
    else:
        print('binary:\n\t/opt/homebrew/lib/missing.dylib (compatibility version 1)')
elif name == 'lipo':
    print(os.environ.get('SKYPC_EXPECTED_ARCH', 'arm64'))
elif name == 'xattr':
    if case == 'xattr-fail': sys.exit(14)
    if a[0] == '-r' and case == 'dirty-xattrs': print(a[-1] + ': com.apple.quarantine'); sys.exit(0)
    sys.exit(subprocess.call(['/usr/bin/xattr', *a]))
elif name == 'sips':
    # Reproduce the original failure: metadata setter succeeds without applying DPI.
    if a[:2] == ['-s', 'dpiWidth']: sys.exit(0)
    sys.exit(subprocess.call(['/usr/bin/sips', *a]))
elif name == 'ditto':
    subprocess.run(['/usr/bin/ditto', *a], check=True)
    (pathlib.Path(a[-1]) / 'Contents/Info.plist').write_text('tampered staging')
elif name == 'hdiutil':
    if case == 'attach-fail' and a[0] == 'attach': sys.exit(10)
    if a[0] == 'create':
        subprocess.run(['/usr/bin/ditto', a[a.index('-srcfolder') + 1], str(state / 'volume')], check=True)
        pathlib.Path(a[-1]).write_bytes(b'FAKE DISK IMAGE')
    elif a[0] == 'attach':
        assert '-mountpoint' not in a and '-plist' in a
        mount = state / 'SkyPC 2'
        subprocess.run(['/usr/bin/ditto', str(state / 'volume'), str(mount)], check=True)
        info_path = mount / 'skyPC.app/Contents/Info.plist'
        if info_path.exists():
            with info_path.open('rb') as stream: info = plistlib.load(stream)
            info['LSMinimumSystemVersion'] = (
                '10.12' if ('Intel' in a[1] or os.environ.get('SKYPC_EXPECTED_ARCH') == 'x86_64')
                else '11.0'
            )
            with info_path.open('wb') as stream: plistlib.dump(info, stream)
        (state / 'mount').write_text(str(mount))
        entities = [{'dev-entry': '/dev/disk999'}, {'dev-entry': '/dev/disk999s1', 'mount-point': str(mount)}]
        if case == 'missing-mount': entities.pop()
        sys.stdout.buffer.write(plistlib.dumps({'system-entities': entities}))
        if case == 'partial-attach-fail': sys.exit(10)
    elif a[0] == 'detach':
        assert a[1] == '/dev/disk999', 'Must detach only the returned device'
        if (state / 'mount').exists():
            mount = pathlib.Path((state / 'mount').read_text())
            shutil.rmtree(state / 'volume')
            subprocess.run(['/usr/bin/ditto', str(mount), str(state / 'volume')], check=True)
            shutil.rmtree(mount)
            (state / 'mount').unlink()
    elif a[0] == 'convert': pathlib.Path(a[a.index('-o') + 1]).write_bytes(b'FAKE COMPRESSED DISK IMAGE')
elif name == 'xcrun':
    if a[0] == '--find': print('/mock/' + a[1])
    elif a[0] == 'swift-stdlib-tool':
        destination = pathlib.Path(a[a.index('--destination') + 1])
        destination.mkdir(parents=True, exist_ok=True)
        (destination / 'libswiftCoreMedia.dylib').write_bytes(b'simulated Swift runtime')
    elif a[0] == 'GetFileInfo':
        assert len(a) == 3 and a[1] in ('-aC', '-aV'), 'Invalid GetFileInfo syntax'
        print('1')
    elif a[:2] == ['notarytool', 'submit']:
        if case == 'malformed': print('not a plist'); sys.exit(0)
        status = 'Invalid' if case == 'invalid' else 'Accepted'
        sys.stdout.buffer.write(plistlib.dumps({'status': status, 'id': 'test-submission'}))
        if case == 'submit-fail': sys.exit(12)
    elif a[:2] == ['notarytool', 'log']: pathlib.Path(a[-1]).write_text('{"issues": ["simulated rejection"]}')
    elif a[:2] == ['stapler', 'staple'] and case == 'staple-fail': sys.exit(13)
'''


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='skypc-contract-')
        self.base = Path(self.tmp.name)
        self.bin = self.base / 'tools'
        self.bin.mkdir()
        self.state = self.base / 'state'
        self.state.mkdir()
        (self.state / 'SkyPC').mkdir()
        (self.state / 'SkyPC/keep').write_text('unrelated mounted volume')
        self.mock = self.bin / 'service'
        self.mock.write_text(MOCK)
        self.mock.chmod(0o755)
        for tool in ('codesign', 'security', 'hdiutil', 'osascript', 'spctl', 'xcrun', 'layout-python', 'lipo'):
            (self.bin / tool).symlink_to(self.mock)
        self.envfile = self.base / '.env'
        self.write_env('NOTARY_AUTH=keychain\n')
        self.output = self.base / 'release with spaces'
        self.env = dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH'], MOCK_STATE=str(self.state),
                        SKYPC_LAYOUT_PYTHON=str(self.bin / 'layout-python'))
        self.input = self.base / 'input with spaces'
        # A system executable is sufficient for the binary-only pipeline contract.
        shutil.copyfile('/usr/bin/true', self.input)
        self.original = self.input.read_bytes()

    def tearDown(self):
        self.tmp.cleanup()

    def write_env(self, text):
        self.envfile.write_text(text)
        self.envfile.chmod(0o600)

    def run_release(self, *options, case=''):
        self.env['MOCK_CASE'] = case
        result = subprocess.run(
            ['/bin/bash', str(ROOT / 'release_skypc.sh'), str(self.input),
             '--env', str(self.envfile), '--output-dir', str(self.output),
             '--skip-smoke-test', *options], env=self.env, text=True, capture_output=True)
        self.assertEqual(self.original, self.input.read_bytes())
        return result

    def trace(self):
        p = self.state / 'trace'
        return p.read_text() if p.exists() else ''

    def test_accepted_pipeline_and_metadata(self):
        r = self.run_release('--version', '1.2.3', '--build', '7')
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        final_dmg = self.output / 'dist/skypc_1.2.3-7_arm64.dmg'
        self.assertTrue(final_dmg.exists())
        self.assertTrue((self.output / 'dist/skypc_1.2.3-7_arm64.dmg.sha256').exists())
        self.assertTrue((self.output / 'dist/INSTALL.txt').exists())
        self.assertFalse((self.output / 'build/dmg-root/INSTALL.txt').exists())
        self.assertTrue((self.output / 'build/finder.DS_Store').is_file())
        app = self.output / 'build/SkyPC.app'
        with (app / 'Contents/Info.plist').open('rb') as f:
            info = plistlib.load(f)
        self.assertEqual(info['CFBundleShortVersionString'], '1.2.3')
        self.assertEqual(info['CFBundleIdentifier'], 'com.sub2s.skypc')
        self.assertEqual(info['LSMinimumSystemVersion'], '11.0')
        self.assertEqual(info['CFBundleIconFile'], 'SkyPC.icns')
        self.assertEqual(info['CFBundleURLTypes'], [{
            'CFBundleTypeRole': 'Viewer',
            'CFBundleURLName': 'com.sub2s.skypc.oidc',
            'CFBundleURLSchemes': ['skypc'],
        }])
        self.assertEqual(
            info['NSLocalNetworkUsageDescription'],
            'SkyPC uses the local network to connect to computers you choose for remote desktop and game streaming.',
        )
        self.assertNotIn('LSUIElement', info)
        self.assertEqual((app / 'Contents/Resources/SkyPC.icns').stat().st_mode & 0o777, 0o644)
        self.assertIn('runtime=unverified', (self.output / 'release-evidence.txt').read_text())
        self.assertIn('artifact=skypc_1.2.3-7_arm64.dmg',
                      (self.output / 'release-evidence.txt').read_text())
        self.assertIn('minimum macOS=11.0',
                      (self.output / 'release-evidence.txt').read_text())
        self.assertIn('template/SkyPC.entitlements',
                      (self.output / 'release-evidence.txt').read_text())
        with (self.output / 'signed-entitlements.plist').open('rb') as stream:
            self.assertEqual(plistlib.load(stream), {
                'com.apple.security.device.audio-input': True,
                'com.apple.security.device.camera': True,
            })
        trace = self.trace()
        osascript_index = trace.index('osascript ')
        self.assertLess(osascript_index, trace.index('layout-python ', osascript_index))
        self.assertLess(osascript_index, trace.index('xcrun SetFile'))
        self.assertLess(trace.index('xcrun notarytool'), trace.index('xcrun stapler'))
        self.assertFalse((self.state / 'mount').exists())
        self.assertEqual((self.state / 'SkyPC/keep').read_text(), 'unrelated mounted volume')
        staged = self.output / 'build/dmg-root/SkyPC.app'
        self.assertTrue((staged / 'Contents/_CodeSignature/CodeResources').exists())
        self.assertEqual(subprocess.check_output(['/usr/bin/xattr', '-p', 'com.skypc.test.signed', str(staged)]).strip(),
                         b'preserve signed metadata')
        self.assertEqual(subprocess.run(['shasum', '-a', '256', '-c', 'skypc_1.2.3-7_arm64.dmg.sha256'],
                                       cwd=self.output / 'dist', capture_output=True).returncode, 0)

    def test_architecture_specific_output_names(self):
        x86_output = self.base / 'x86 release'
        x86_env = dict(self.env, SKYPC_EXPECTED_ARCH='x86_64')
        result = subprocess.run(
            ['/bin/bash', str(ROOT / 'release_skypc.sh'), str(self.input),
             '--env', str(self.envfile), '--output-dir', str(x86_output),
             '--skip-smoke-test', '--version', '1.2.3', '--build', '8',
             '--minimum-os', '10.12'],
            env=x86_env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue((x86_output / 'dist/skypc_1.2.3-8_x86_64.dmg').exists())
        self.assertTrue((x86_output / 'dist/skypc_1.2.3-8_x86_64.dmg.sha256').exists())
        self.assertIn('artifact=skypc_1.2.3-8_x86_64.dmg',
                      (x86_output / 'release-evidence.txt').read_text())

        universal_output = self.base / 'universal prepare'
        universal_env = dict(self.env, SKYPC_EXPECTED_ARCH='arm64 x86_64')
        result = subprocess.run(
            ['/bin/bash', str(ROOT / 'release_skypc.sh'), str(self.input),
             '--env', str(self.envfile), '--output-dir', str(universal_output),
             '--skip-smoke-test', '--prepare-only', '--version', '1.2.3', '--build', '9'],
            env=universal_env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('artifact=skypc_1.2.3-9_universal.dmg',
                      (universal_output / 'release-evidence.txt').read_text())

    def test_failures_never_publish(self):
        for case in ('invalid', 'malformed', 'submit-fail', 'sign-fail', 'staple-fail', 'assess-fail',
                     'attach-fail', 'partial-attach-fail', 'missing-mount', 'layout-fail', 'layout-verify-fail'):
            with self.subTest(case=case):
                self.output = self.base / case
                for child in self.state.iterdir():
                    if child.is_dir(): shutil.rmtree(child)
                    else: child.unlink()
                r = self.run_release(case=case)
                self.assertNotEqual(r.returncode, 0, case)
                self.assertFalse(any((self.output / 'dist').glob('skypc_*.dmg')), case)
                self.assertFalse((self.state / 'mount').exists(), case)
                self.assertIn('FAILED', (self.output / 'release-evidence.txt').read_text())
                if case in ('invalid', 'malformed', 'submit-fail', 'sign-fail', 'layout-fail'):
                    self.assertNotIn('xcrun stapler', self.trace())
                if case in ('layout-fail', 'layout-verify-fail'):
                    self.assertNotIn('xcrun notarytool', self.trace())
                if case == 'invalid': self.assertTrue((self.output / 'notary-log.json').exists())

    def test_prepare_only_has_no_external_services(self):
        r = self.run_release('--prepare-only')
        self.assertEqual(r.returncode, 0, r.stderr)
        # Architecture detection is a local Mach-O preflight needed for the
        # production package name. Prepare-only must still avoid signing,
        # disk-image, Finder, and Apple services.
        self.assertEqual(self.trace(), 'lipo -archs\n')
        self.assertFalse(any((self.output / 'dist').glob('skypc_*.dmg')))
        self.assertTrue((self.output / 'build/SkyPC.app').is_dir())
        self.assertFalse((self.output / 'build/dmg-root').exists())

    def test_smappservice_launch_agent_is_embedded_and_recorded(self):
        agent = ROOT / 'template/com.sub2s.skypc.login-agent.plist'
        r = self.run_release('--launch-agent-plist', str(agent))
        self.assertEqual(r.returncode, 0, r.stderr)
        embedded = (self.output / 'build/SkyPC.app/Contents/Library/LaunchAgents' /
                    'com.sub2s.skypc.login-agent.plist')
        self.assertEqual(embedded.read_bytes(), agent.read_bytes())
        with embedded.open('rb') as f:
            config = plistlib.load(f)
        self.assertEqual(config['Label'], 'com.sub2s.skypc.login-agent')
        self.assertEqual(config['AssociatedBundleIdentifiers'], 'com.sub2s.skypc')
        self.assertEqual(config['BundleProgram'], 'Contents/MacOS/skypc')
        self.assertEqual(config['ProgramArguments'], ['skypc', '--hidden'])
        self.assertIn('login item=SMAppService bundled LaunchAgent',
                      (self.output / 'release-evidence.txt').read_text())

    def test_smappservice_wrapper_rejects_legacy_binary(self):
        result = subprocess.run(
            ['/bin/bash', str(ROOT / 'release_skypc_smappservice.sh'), str(self.input),
             '--prepare-only', '--output-dir', str(self.output)],
            env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('does not contain the SMAppService login-item flow', result.stderr)
        self.assertFalse(self.output.exists())

    def test_legacy_v2_wrapper_prepares_without_bundled_launch_agent(self):
        result = subprocess.run(
            ['/bin/bash', str(ROOT / 'release_skypc_v2.sh'), str(self.input),
             '--env', str(self.envfile), '--prepare-only', '--output-dir', str(self.output)],
            env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        app = self.output / 'build/SkyPC.app'
        self.assertTrue(app.is_dir())
        self.assertFalse((app / 'Contents/Library/LaunchAgents').exists())
        self.assertNotIn('login item=SMAppService',
                         (self.output / 'release-evidence.txt').read_text())

    def test_legacy_v2_wrapper_rejects_smappservice_binary(self):
        marked_binary = self.base / 'smappservice binary'
        marked_binary.write_bytes(
            self.original + b'com.sub2s.skypc.login-agent.plist')
        result = subprocess.run(
            ['/bin/bash', str(ROOT / 'release_skypc_v2.sh'), str(marked_binary),
             '--env', str(self.envfile), '--prepare-only', '--output-dir', str(self.output)],
            env=self.env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('still contains the SMAppService login flow', result.stderr)
        self.assertFalse(self.output.exists())

    def test_v3_rejects_direct_rebuild_modes(self):
        for arguments in (('arm64',), ('all',), ('--binary', str(self.input))):
            with self.subTest(arguments=arguments):
                result = subprocess.run(
                    ['/bin/bash', str(ROOT / 'release_skypc_v3.sh'), *arguments,
                     '--build', '13'],
                    env=self.env, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('build_mac_artifact.sh all', result.stderr)

    def test_v3_from_build_all_reuses_both_existing_artifacts(self):
        app_repo = self.base / 'skypc-app'
        app_repo.mkdir()
        (app_repo / 'Cargo.toml').write_text('[workspace.package]\nversion = "0.9.38"\n')
        build_script = app_repo / 'build_mac_artifact.sh'
        build_script.write_text('#!/bin/sh\necho unexpected-rebuild >&2\nexit 91\n')
        build_script.chmod(0o755)

        artifacts = (
            ('aarch64-apple-darwin', 'skyPC-macOS-AppleSilicon.dmg'),
            ('x86_64-apple-darwin', 'skyPC-macOS-Intel.dmg'),
        )
        for target, dmg_name in artifacts:
            binary = app_repo / 'target' / target / 'release/skypc'
            binary.parent.mkdir(parents=True)
            shutil.copyfile('/usr/bin/true', binary)
            dmg = app_repo / 'dist' / dmg_name
            dmg.parent.mkdir(exist_ok=True)
            dmg.write_bytes(('EXISTING ' + target).encode())

        volume = self.state / 'volume'
        app = volume / 'skyPC.app/Contents'
        (app / 'MacOS').mkdir(parents=True)
        (app / '_CodeSignature').mkdir()
        (app / '_CodeSignature/CodeResources').write_text('ad-hoc build signature')
        shutil.copyfile('/usr/bin/true', app / 'MacOS/skypc')
        with (app / 'Info.plist').open('wb') as stream:
            plistlib.dump({
                'CFBundleIdentifier': 'com.skypc.client',
                'CFBundleShortVersionString': '0.9.38',
                'CFBundleURLTypes': [{
                    'CFBundleTypeRole': 'Viewer',
                    'CFBundleURLName': 'com.skypc.client.oidc',
                    'CFBundleURLSchemes': ['skypc'],
                }],
            }, stream)
        subprocess.run(['/usr/bin/xattr', '-w', 'com.skypc.test.signed',
                        'preserve signed metadata', str(volume / 'skyPC.app')], check=True)

        env = dict(self.env, SKYPC_APP_DIR=str(app_repo))
        result = subprocess.run(
            ['/bin/bash', str(ROOT / 'release_skypc_v3.sh'), '--from-build', 'all',
             '--build', '13', '--env', str(self.envfile), '--prepare-only',
             '--output-dir', str(self.output)],
            env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertNotIn('unexpected-rebuild', result.stdout + result.stderr)
        for arch, (_, dmg_name) in zip(('arm64', 'x86_64'), artifacts):
            output = self.output / arch
            self.assertTrue((output / 'build/SkyPC.app').is_dir())
            with (output / 'build/SkyPC.app/Contents/Info.plist').open('rb') as stream:
                info = plistlib.load(stream)
            self.assertEqual(info['LSMinimumSystemVersion'],
                             '11.0' if arch == 'arm64' else '10.12')
            evidence = (output / 'release-evidence.txt').read_text()
            self.assertIn(str(app_repo / 'dist' / dmg_name), evidence)
            self.assertIn('preparation=passed', evidence)

    def test_clean_template_without_old_app_and_download_metadata(self):
        # Standalone script installation has no old SkyPC.app to read or modify.
        workspace = self.base / 'standalone'
        (workspace / 'template').mkdir(parents=True)
        shutil.copyfile(ROOT / 'release_skypc.sh', workspace / 'release_skypc.sh')
        shutil.copyfile(ROOT / 'template/Info.plist', workspace / 'template/Info.plist')
        shutil.copyfile(ROOT / 'template/SkyPC.entitlements',
                        workspace / 'template/SkyPC.entitlements')
        shutil.copyfile(ROOT / 'SkyPC.icns', workspace / 'SkyPC.icns')
        shutil.copyfile(ROOT / 'dmg_layout.py', workspace / 'dmg_layout.py')
        shutil.copyfile(ROOT / 'finder_layout.applescript', workspace / 'finder_layout.applescript')
        shutil.copyfile(ROOT.parent / 'skypc-app/assets/background.jpg', workspace / 'background.jpg')
        sources = (self.input, workspace / 'template/Info.plist', workspace / 'SkyPC.icns')
        for source in sources:
            subprocess.run(['/usr/bin/xattr', '-w', 'com.apple.quarantine', '0081;00000000;ContractTest;', str(source)], check=True)
            subprocess.run(['/usr/bin/xattr', '-w', 'com.skypc.test.download', 'private download metadata', str(source)], check=True)
        r = subprocess.run(['/bin/bash', str(workspace / 'release_skypc.sh'), str(self.input),
                            '--icon', str(workspace / 'SkyPC.icns'), '--background', str(workspace / 'background.jpg'),
                            '--prepare-only', '--output-dir', str(self.output)],
                           env=self.env, capture_output=True, text=True)
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        app = self.output / 'build/SkyPC.app'
        attributes = subprocess.check_output(['/usr/bin/xattr', '-r', str(app)], text=True)
        self.assertTrue(all(line.endswith(': com.apple.provenance') for line in attributes.splitlines()))
        with (app / 'Contents/Info.plist').open('rb') as f:
            info = plistlib.load(f)
        with (workspace / 'template/Info.plist').open('rb') as f:
            self.assertEqual(info['CFBundleVersion'], plistlib.load(f)['CFBundleVersion'])
        for source in sources:
            self.assertIn('com.apple.quarantine', subprocess.check_output(['/usr/bin/xattr', str(source)], text=True))

    def test_dirty_or_unreadable_xattrs_stop_before_signing(self):
        (self.bin / 'xattr').symlink_to(self.mock)
        for case in ('dirty-xattrs', 'xattr-fail'):
            with self.subTest(case=case):
                self.output = self.base / case
                r = self.run_release(case=case)
                self.assertNotEqual(r.returncode, 0)
                self.assertNotIn('codesign --force', self.trace())
                self.assertNotIn('private download metadata', r.stdout + r.stderr)

    def test_staging_corruption_stops_before_image_creation(self):
        (self.bin / 'ditto').symlink_to(self.mock)
        r = self.run_release()
        self.assertNotEqual(r.returncode, 0)
        self.assertNotIn('hdiutil create', self.trace())

    def test_existing_output_is_preserved(self):
        self.output.mkdir()
        marker = self.output / 'keep'
        marker.write_text('previous release')
        r = self.run_release('--prepare-only')
        self.assertNotEqual(r.returncode, 0)
        self.assertEqual(marker.read_text(), 'previous release')
        self.assertEqual(list(self.output.iterdir()), [marker])

    def test_env_literals_are_not_executed_or_logged(self):
        marker = self.base / 'must-not-exist'
        secret = f'$(touch {marker})`touch {marker}`'
        self.write_env(f'NOTARY_AUTH=apple-id\nAPPLE_ID=test@example.invalid\nAPPLE_APP_SPECIFIC_PASSWORD=\'{secret}\'\n')
        r = self.run_release()
        self.assertEqual(r.returncode, 0, r.stderr)
        self.assertFalse(marker.exists())
        self.assertNotIn(secret, r.stdout + r.stderr)
        for f in self.output.glob('*.log'):
            self.assertNotIn(secret, f.read_text())
        self.assertNotIn(secret, (self.output / 'release-evidence.txt').read_text())

    def test_insecure_env_is_rejected(self):
        self.envfile.chmod(0o644)
        r = self.run_release('--prepare-only')
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_unknown_env_key_is_rejected(self):
        self.write_env('PATH=/malicious\n')
        self.assertNotEqual(self.run_release('--prepare-only').returncode, 0)
        self.assertFalse(self.output.exists())

    def test_required_media_entitlements_cannot_be_omitted(self):
        incomplete = self.base / 'incomplete.entitlements'
        with incomplete.open('wb') as stream:
            plistlib.dump({'com.apple.security.device.camera': True}, stream)
        result = self.run_release('--prepare-only', '--entitlements', str(incomplete))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('com.apple.security.device.audio-input', result.stderr)
        self.assertFalse(self.output.exists())

    def test_unreviewed_entitlements_are_rejected_for_developer_id_flow(self):
        forbidden = (
            'com.apple.security.app-sandbox',
            'com.apple.security.network.client',
            'com.apple.security.network.server',
            'com.apple.security.device.usb',
            'com.apple.security.device.bluetooth',
            'com.apple.security.device.microphone',
            'com.apple.security.cs.allow-jit',
            'com.apple.security.cs.allow-unsigned-executable-memory',
            'com.apple.security.cs.disable-library-validation',
        )
        for index, entitlement in enumerate(forbidden):
            with self.subTest(entitlement=entitlement):
                invalid = self.base / f'forbidden-{index}.entitlements'
                with invalid.open('wb') as stream:
                    plistlib.dump({
                        'com.apple.security.device.audio-input': True,
                        'com.apple.security.device.camera': True,
                        entitlement: True,
                    }, stream)
                result = self.run_release(
                    '--prepare-only', '--entitlements', str(invalid))
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(entitlement, result.stderr)
                self.assertFalse(self.output.exists())

    def test_local_network_usage_description_is_required(self):
        incomplete = self.base / 'incomplete-info.plist'
        with (ROOT / 'template/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        info.pop('NSLocalNetworkUsageDescription')
        with incomplete.open('wb') as stream:
            plistlib.dump(info, stream)
        result = self.run_release('--prepare-only', '--plist', str(incomplete))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('NSLocalNetworkUsageDescription', result.stderr)
        self.assertFalse(self.output.exists())

    def test_oidc_url_scheme_is_required(self):
        incomplete = self.base / 'missing-oidc-url-scheme.plist'
        with (ROOT / 'template/Info.plist').open('rb') as stream:
            info = plistlib.load(stream)
        info.pop('CFBundleURLTypes')
        with incomplete.open('wb') as stream:
            plistlib.dump(info, stream)
        result = self.run_release('--prepare-only', '--plist', str(incomplete))
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('CFBundleURLTypes', result.stderr)
        self.assertFalse(self.output.exists())

    def test_non_system_dependency_is_rejected(self):
        (self.bin / 'otool').symlink_to(self.mock)
        self.assertNotEqual(self.run_release('--prepare-only').returncode, 0)
        self.assertFalse(self.output.exists())

    def test_swift_system_rpath_is_narrowly_allowed(self):
        (self.bin / 'otool').symlink_to(self.mock)
        self.env['MOCK_OTOOL_MODE'] = 'swift-system'
        result = self.run_release('--prepare-only')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_intel_1012_bundles_swift_runtime(self):
        (self.bin / 'otool').symlink_to(self.mock)
        self.env['MOCK_OTOOL_MODE'] = 'swift-local'
        result = self.run_release('--prepare-only', '--minimum-os', '10.12')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        framework = self.output / 'build/SkyPC.app/Contents/Frameworks/libswiftCoreMedia.dylib'
        self.assertTrue(framework.is_file())
        with (self.output / 'build/SkyPC.app/Contents/Info.plist').open('rb') as stream:
            self.assertEqual(plistlib.load(stream)['LSMinimumSystemVersion'], '10.12')

    def test_swift_dependency_with_non_system_rpath_is_rejected(self):
        (self.bin / 'otool').symlink_to(self.mock)
        self.env['MOCK_OTOOL_MODE'] = 'swift-unsafe'
        result = self.run_release('--prepare-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_missing_icon_is_rejected(self):
        r = self.run_release('--prepare-only', '--icon', str(self.base / 'absent.icns'))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_missing_background_is_rejected(self):
        r = self.run_release('--prepare-only', '--background', str(self.base / 'missing.jpg'))
        self.assertNotEqual(r.returncode, 0)
        self.assertFalse(self.output.exists())

    def test_background_density_write_must_be_verified(self):
        (self.bin / 'sips').symlink_to(self.mock)
        result = self.run_release('--prepare-only')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Background logical size does not match Finder canvas', result.stderr)
        self.assertNotIn('codesign --force', self.trace())


if __name__ == '__main__':
    unittest.main(verbosity=2)
