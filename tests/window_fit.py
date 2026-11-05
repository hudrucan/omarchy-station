import json
import os
import pathlib
import shlex
import shutil
import signal
import subprocess
import tempfile
import time

repo = pathlib.Path(__file__).resolve().parents[1]
tmp = pathlib.Path(tempfile.mkdtemp(prefix='of-', dir='/tmp'))
runtime = tmp / 'r'
runtime.mkdir(mode=0o700)
env = dict(os.environ, XDG_RUNTIME_DIR=str(runtime), AQ_BACKEND='headless',
           AQ_DRM_DEVICES='/dev/null', WLR_BACKENDS='headless',
           QT_QPA_PLATFORM='wayland', XDG_SESSION_TYPE='wayland')
env['XDG_CACHE_HOME'] = str(tmp / 'cache')
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
hl.monitor({output="BASE",mode="1920x1080@60",position="0x0",scale=1})
hl.monitor({output="RDP-1",mode="2560x1440@60",position="1920x0",scale=1})
hl.config({animations={enabled=false},misc={disable_hyprland_logo=true,disable_splash_rendering=true},general={border_size=0}})
''')
qml = tmp / 'shell.qml'
qml.write_text('''
import QtQuick
import Quickshell
ShellRoot {
  FloatingWindow { visible: true; title: "fit-offscreen"; implicitWidth: 400; implicitHeight: 500 }
  FloatingWindow { visible: true; title: "fit-oversized"; implicitWidth: 1400; implicitHeight: 1350 }
  FloatingWindow { visible: true; title: "fit-minimum"; implicitWidth: 1000; implicitHeight: 1500; minimumSize: Qt.size(900, 1400) }
  FloatingWindow { visible: true; title: "fit-unchanged"; implicitWidth: 300; implicitHeight: 300 }
  FloatingWindow { visible: true; title: "fit-physical"; implicitWidth: 900; implicitHeight: 700 }
}
''')
children = []

def command(*args):
    return subprocess.run(args, env=env, text=True, capture_output=True, timeout=10)

def hypr(*args):
    result = command('hyprctl', *args)
    if result.returncode:
        raise RuntimeError(result.stderr or result.stdout)
    return result.stdout

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
            raise RuntimeError('Nested Hyprland exited: ' + (tmp / 'hyprland.log').read_text()[-2500:])
        time.sleep(.1)
    else:
        raise RuntimeError('Nested compositor timed out: ' + (tmp / 'hyprland.log').read_text()[-4500:])
    waylands = [p for p in runtime.glob('wayland-*') if not p.name.endswith('.lock')]
    env['WAYLAND_DISPLAY'] = waylands[0].name
    hypr('output', 'create', 'headless', 'BASE')
    hypr('output', 'create', 'headless', 'RDP-1')
    time.sleep(.35)
    hypr('eval', 'for id,mon in ipairs({"RDP-1","RDP-1","BASE"}) do hl.workspace_rule({workspace=tostring(id),monitor=mon,persistent=true}); hl.dispatch(hl.dsp.focus({workspace=tostring(id)})); hl.dispatch(hl.dsp.workspace.move({workspace=tostring(id),monitor=mon})) end; hl.dispatch(hl.dsp.focus({workspace="1"}))')
    with (tmp / 'fixture.log').open('w') as log:
        children.append(subprocess.Popen(['quickshell', '-n', '-p', str(tmp)], env=env,
                                        stdout=log, stderr=log, start_new_session=True))
    for _ in range(70):
        windows = json.loads(hypr('-j', 'clients'))
        if len([w for w in windows if w.get('title', '').startswith('fit-')]) == 5:
            break
        if children[1].poll() is not None:
            raise RuntimeError('Fixture exited: ' + (tmp / 'fixture.log').read_text()[-2000:])
        time.sleep(.1)
    else:
        raise RuntimeError('Fixture windows timed out')
    result = subprocess.run(shlex.split(os.environ.get('ZIG', 'mise exec -- zig')) + [
        'build', 'test-window-fit',
        '--cache-dir', os.environ['ZIG_LOCAL_CACHE_DIR'],
        '-Doptimize=' + os.environ.get('OPTIMIZE', 'ReleaseSafe'), '-j' + os.environ.get('JOBS', '2')
    ], cwd=repo, env=env, text=True, capture_output=True, timeout=240)
    print('integration exit:', result.returncode)
    print((result.stdout + result.stderr)[-4500:])
    if result.returncode:
        print('fixture monitors:', json.dumps([
            {key: m.get(key) for key in ['name', 'id', 'x', 'y', 'width', 'height', 'scale']}
            for m in json.loads(hypr('-j', 'monitors'))]))
        print('fixture geometries:', json.dumps([
            {key: w.get(key) for key in ['title', 'at', 'size', 'monitor', 'workspace']}
            for w in json.loads(hypr('-j', 'clients'))]))
        raise SystemExit(result.returncode)
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
