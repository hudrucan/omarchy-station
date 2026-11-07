"""Exercise real cursor snapshots in an isolated, unpatched Hyprland."""
import json
import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time

plugin = pathlib.Path(os.environ['OMASTATION_PLUGIN']).resolve(strict=True)
tmp = pathlib.Path(tempfile.mkdtemp(prefix='oc-', dir='/tmp'))
runtime = tmp / 'r'
runtime.mkdir(mode=0o700)
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), AQ_BACKEND='headless',
           AQ_DRM_DEVICES='/dev/null', WLR_BACKENDS='headless',
           QT_QPA_PLATFORM='wayland', XDG_SESSION_TYPE='wayland',
           XDG_CACHE_HOME=str(tmp / 'cache'), XCURSOR_THEME='Adwaita', XCURSOR_SIZE='24')
for key in ['WAYLAND_DISPLAY', 'DISPLAY', 'HYPRLAND_INSTANCE_SIGNATURE']:
    env.pop(key, None)
parent_runtime = os.environ.get('XDG_RUNTIME_DIR', f'/run/user/{os.getuid()}')
instances = json.loads(subprocess.check_output(['hyprctl', '-j', 'instances'],
    env=dict(os.environ, XDG_RUNTIME_DIR=parent_runtime), text=True))
if len(instances) != 1:
    raise RuntimeError('Expected one parent compositor for the nested allocator')
env['WAYLAND_DISPLAY'] = str(pathlib.Path(parent_runtime) / instances[0]['wl_socket'])
config = tmp / 'hyprland.lua'
config.write_text('''
hl.monitor({output="HEADLESS-1",disabled=true})
hl.monitor({output="WAYLAND-1",disabled=true})
hl.monitor({output="RDP-1",mode="800x600@60",position="0x0",scale=1})
hl.config({animations={enabled=false},misc={disable_hyprland_logo=true,disable_splash_rendering=true,disable_watchdog_warning=true},general={border_size=0}})
''')
(tmp / 'shell.qml').write_text('''
import QtQuick
import Quickshell
import Quickshell.Io
ShellRoot {
  FloatingWindow {
    visible: true; title: "cursor-fixture"; implicitWidth: 600; implicitHeight: 400
    MouseArea { id: mouse; anchors.fill: parent; hoverEnabled: true; cursorShape: Qt.ArrowCursor }
  }
  IpcHandler {
    target: "cursor-test"
    function arrow(): void { mouse.cursorShape = Qt.ArrowCursor }
    function hand(): void { mouse.cursorShape = Qt.PointingHandCursor }
    function blank(): void { mouse.cursorShape = Qt.BlankCursor }
  }
}
''')
children = []


def run(*args):
    return subprocess.run(args, env=env, text=True, capture_output=True, timeout=10)


def hypr(*args):
    result = run('hyprctl', *args)
    if result.returncode or 'Lua error' in result.stdout or 'unknown request' in result.stdout:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout.strip()


def snapshot(known=None):
    args = ['omastation-cursor-image'] + ([known] if known else [])
    reply = hypr(*args)
    if reply in ['hidden', 'unavailable']:
        return reply
    fields = reply.split()
    assert len(fields) == 7 and fields[0] == 'v1', reply[:100]
    w, h, hx, hy = map(int, fields[1:5])
    assert 0 < w <= 256 and 0 < h <= 256 and 0 <= hx < w and 0 <= hy < h
    assert len(fields[5]) == 16
    if fields[6] == 'same':
        assert known == fields[5]
    else:
        pixels = bytes.fromhex(fields[6])
        assert len(pixels) == w * h * 4 and any(pixels[3::4])
    return fields


def change_cursor(shape):
    result = run('quickshell', 'ipc', '-p', str(tmp), 'call', 'cursor-test', shape)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    time.sleep(.2)


try:
    with (tmp / 'hyprland.log').open('w') as log:
        children.append(subprocess.Popen(['Hyprland', '--config', str(config)], env=env,
                                        stdout=log, stderr=log, start_new_session=True))
    for _ in range(100):
        sockets = list(runtime.glob('hypr/*/.socket.sock'))
        if sockets:
            env['HYPRLAND_INSTANCE_SIGNATURE'] = sockets[0].parent.name
            break
        if children[0].poll() is not None:
            raise RuntimeError('Nested compositor exited')
        time.sleep(.1)
    else:
        raise RuntimeError('Nested compositor timed out')
    env['WAYLAND_DISPLAY'] = next(p.name for p in runtime.glob('wayland-*') if not p.name.endswith('.lock'))
    hypr('output', 'create', 'headless', 'RDP-1')
    time.sleep(.3)
    hypr('plugin', 'load', str(plugin))
    assert '[rdp-cursor-image-v1]' in hypr('plugin', 'list')
    # Theme cursor outside the fixture: real pixels, followed by a cache hit.
    hypr('eval', 'hl.dispatch(hl.dsp.cursor.move({x=780,y=580}))')
    theme = snapshot()
    assert isinstance(theme, list), f'Theme snapshot: {theme}'
    assert snapshot(theme[5])[6] == 'same'
    with (tmp / 'fixture.log').open('w') as log:
        children.append(subprocess.Popen(['quickshell', '-n', '-p', str(tmp)], env=env,
                                        stdout=log, stderr=log, start_new_session=True))
    for _ in range(70):
        windows = json.loads(hypr('-j', 'clients'))
        fixture = next((w for w in windows if w.get('title') == 'cursor-fixture'), None)
        if fixture:
            break
        time.sleep(.1)
    else:
        raise RuntimeError('Cursor fixture timed out')
    x, y = fixture['at']
    hypr('eval', f'hl.dispatch(hl.dsp.cursor.move({{x={x + 80},y={y + 80}}}))')
    time.sleep(.2)
    arrow = snapshot()
    assert isinstance(arrow, list), f'Wayland cursor snapshot: {arrow}'
    change_cursor('hand')
    hand = snapshot()
    assert isinstance(hand, list) and hand[5] != arrow[5], 'Cursor change did not change its snapshot'
    assert snapshot(hand[5])[6] == 'same'
    change_cursor('blank')
    assert snapshot() == 'hidden', 'A transparent application cursor must remain hidden'
    change_cursor('arrow')
    assert isinstance(snapshot(), list), 'Cursor did not recover after being hidden'
    print('Cursor snapshot integration passed: theme, Wayland shape changes, cache, hidden and recovery on stock Hyprland')
except Exception:
    for name in ['hyprland.log', 'fixture.log']:
        path = tmp / name
        if path.exists():
            print(name + ':\n' + path.read_text()[-2000:])
    raise
finally:
    for process in reversed(children):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
    for process in children:
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
    shutil.rmtree(tmp)
