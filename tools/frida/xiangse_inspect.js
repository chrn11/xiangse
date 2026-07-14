/**
 * 香色阅读真机透视 — Frida attach 脚本
 *
 * 前置：设备已装 frida-server（TrollStore + RootHide 可 sideload），PC 端 pip install frida-tools
 * 用法：python tools/frida_inspect.py dump|refresh
 *       或 frida -U -n StandarReader -l tools/frida/xiangse_inspect.js
 */
'use strict';

function keyWindow() {
  const app = ObjC.classes.UIApplication.sharedApplication();
  if (app.keyWindow && app.keyWindow()) return app.keyWindow();
  const scenes = app.connectedScenes();
  if (!scenes) return null;
  const count = scenes.count().valueOf();
  for (let i = 0; i < count; i++) {
    const scene = scenes.objectAtIndex_(i);
    if (!scene || !scene.isKindOfClass_(ObjC.classes.UIWindowScene)) continue;
    const wins = scene.windows();
    if (!wins) continue;
    const wc = wins.count().valueOf();
    for (let j = 0; j < wc; j++) {
      const w = wins.objectAtIndex_(j);
      if (w && w.isKeyWindow && w.isKeyWindow()) return w;
    }
  }
  return null;
}

function vcStack(root) {
  const out = [];
  if (!root) return out;
  let cur = root;
  while (cur) {
    out.push(cur);
    const presented = cur.presentedViewController ? cur.presentedViewController() : null;
    if (presented) {
      cur = presented;
      continue;
    }
    if (cur.isKindOfClass_(ObjC.classes.UINavigationController)) {
      const nav = cur;
      const tops = nav.viewControllers ? nav.viewControllers() : null;
      if (tops && tops.count() > 0) {
        cur = tops.objectAtIndex_(tops.count() - 1);
        continue;
      }
    }
    if (cur.isKindOfClass_(ObjC.classes.UITabBarController)) {
      const tab = cur;
      const sel = tab.selectedViewController ? tab.selectedViewController() : null;
      if (sel) {
        cur = sel;
        continue;
      }
    }
    break;
  }
  return out;
}

function classNameMatches(obj, needles) {
  if (!obj) return false;
  const n = obj.$className || '';
  for (let i = 0; i < needles.length; i++) {
    if (n.indexOf(needles[i]) >= 0) return true;
  }
  return false;
}

function findTextReadHost(stack) {
  for (let i = stack.length - 1; i >= 0; i--) {
    const vc = stack[i];
    if (classNameMatches(vc, ['TextRead', 'ReadVC', 'TextRPage'])) return vc;
  }
  return null;
}

function findContainer(host) {
  if (!host || !host.view) return null;
  const queue = [host.view()];
  const seen = new Set();
  while (queue.length > 0) {
    const v = queue.shift();
    if (!v || seen.has(v.handle.toString())) continue;
    seen.add(v.handle.toString());
    if (classNameMatches(v, ['TextRPageContainer', 'TextReadTV'])) return v;
    const subs = v.subviews ? v.subviews() : null;
    if (subs) {
      const n = subs.count().valueOf();
      for (let i = 0; i < n; i++) queue.push(subs.objectAtIndex_(i));
    }
  }
  return null;
}

function safeKVC(obj, key) {
  try {
    return obj.valueForKey_(key);
  } catch (e) {
    return null;
  }
}

function dumpTextView(tv, label) {
  const info = { key: label, class: tv ? tv.$className : null };
  if (!tv) {
    info.error = 'nil';
    return info;
  }
  try {
    const attr = tv.attributedText ? tv.attributedText() : null;
    info.txtLen = attr ? attr.length() : 0;
    const f = tv.frame();
    info.frame = { x: f[0], y: f[1], w: f[2], h: f[3] };
    info.hidden = tv.isHidden ? tv.isHidden() : null;
    info.alpha = tv.alpha ? tv.alpha() : null;
    const sv = tv.superview ? tv.superview() : null;
    info.superview = sv ? sv.$className : null;
    const subs = tv.subviews ? tv.subviews() : null;
    info.subviewCount = subs ? subs.count().valueOf() : 0;
  } catch (e) {
    info.error = String(e);
  }
  return info;
}

function dumpReadPageModelIvars(model) {
  const ivars = [];
  if (!model) return ivars;
  let cls = model.class ? model.class() : model.$class;
  let parts = 0;
  const NSObject = ObjC.classes.NSObject;
  while (cls && parts < 24) {
    const name = cls.name ? cls.name() : cls.toString();
    if (name === 'NSObject') break;
    const countPtr = Memory.alloc(4);
    const list = ObjC.api.class_copyIvarList(cls.handle, countPtr);
    const count = countPtr.readU32();
    if (list && count > 0) {
      for (let i = 0; i < count && parts < 24; i++) {
        const iv = list.add(i * Process.pointerSize).readPointer();
        const iname = ObjC.api.ivar_getName(iv).readCString();
        const itype = ObjC.api.ivar_getTypeEncoding(iv).readCString();
        let val = '?';
        try {
          const v = ObjC.api.object_getIvar(model.handle, iv);
          if (!v.isNull()) {
            const obj = new ObjC.Object(v);
            if (obj.isKindOfClass_(ObjC.classes.NSAttributedString)) {
              val = 'Attr len=' + obj.length();
            } else if (obj.isKindOfClass_(ObjC.classes.NSString)) {
              const s = obj.toString();
              val = 'NSString len=' + s.length + ' head=' + s.substring(0, 40);
            } else if (obj.isKindOfClass_(ObjC.classes.NSArray)) {
              val = 'NSArray count=' + obj.count();
            } else {
              val = obj.$className;
            }
          } else {
            val = 'null';
          }
        } catch (e2) {
          val = 'err:' + e2;
        }
        ivars.push({ name: iname, type: itype || '?', value: val });
        parts++;
      }
      ObjC.api.free(list);
    }
    cls = ObjC.api.class_getSuperclass(cls.handle);
    if (cls.isNull()) break;
    cls = new ObjC.Object(cls);
  }
  return ivars;
}

function collectReaderDump() {
  const result = { ts: new Date().toISOString(), textViews: [], pageModel: null, host: null, stack: [] };
  const win = keyWindow();
  if (!win) {
    result.error = 'no keyWindow';
    return result;
  }
  const root = win.rootViewController ? win.rootViewController() : null;
  const stack = vcStack(root);
  result.stack = stack.map(function (vc) { return vc.$className; });
  const host = findTextReadHost(stack);
  result.host = host ? host.$className : null;
  const container = host ? (findContainer(host) || host) : null;
  const keys = ['textViewL', 'textViewR', 'curPageTV', 'textView'];
  const target = container || host;
  if (target) {
    for (let k = 0; k < keys.length; k++) {
      const tv = safeKVC(target, keys[k]);
      if (tv) result.textViews.push(dumpTextView(tv, keys[k]));
    }
    let pm = safeKVC(target, 'pageModel');
    if (!pm) pm = safeKVC(target, 'curPageModel');
    if (pm) {
      result.pageModel = {
        class: pm.$className,
        ivars: dumpReadPageModelIvars(pm)
      };
    }
  }
  return result;
}

function forceTextReadTVRefresh(tv) {
  if (!tv) return;
  try {
    tv.setHidden_(false);
    tv.setAlpha_(1.0);
    const sv = tv.superview();
    if (sv && sv.bringSubviewToFront_) sv.bringSubviewToFront_(tv);
    const sels = ['reloadContent', 'reloadView', 'refreshView', 'setNeedsDisplay', 'layoutIfNeeded'];
    for (let i = 0; i < sels.length; i++) {
      const sn = sels[i];
      if (tv.respondsToSelector_(ObjC.selector(sn))) {
        if (sn === 'layoutIfNeeded') tv.layoutIfNeeded();
        else if (sn === 'setNeedsDisplay') tv.setNeedsDisplay();
        else tv.performSelector_(ObjC.selector(sn));
      }
    }
    tv.setNeedsLayout();
    tv.setNeedsDisplay();
    tv.layoutIfNeeded();
    const rcs = ObjC.selector('resetContentPosByScreenSize:');
    if (tv.respondsToSelector_(rcs)) {
      const bounds = ObjC.classes.UIScreen.mainScreen().bounds();
      tv.resetContentPosByScreenSize_(bounds[2], bounds[3]);
    }
  } catch (e) { /* observe only */ }
}

function refreshReader() {
  const out = { refreshed: [], ts: new Date().toISOString() };
  const win = keyWindow();
  if (!win) return out;
  const stack = vcStack(win.rootViewController());
  const host = findTextReadHost(stack);
  const container = host ? (findContainer(host) || host) : null;
  const target = container || host;
  if (!target) return out;
  const keys = ['textViewL', 'textViewR', 'curPageTV', 'textView'];
  for (let k = 0; k < keys.length; k++) {
    const tv = safeKVC(target, keys[k]);
    if (tv) {
      forceTextReadTVRefresh(tv);
      out.refreshed.push(keys[k]);
    }
  }
  const rcs = ObjC.selector('resetContentPosByScreenSize:');
  if (target.respondsToSelector_(rcs)) {
    const bounds = ObjC.classes.UIScreen.mainScreen().bounds();
    target.resetContentPosByScreenSize_(bounds[2], bounds[3]);
    out.refreshed.push('host.resetContentPosByScreenSize');
  }
  return out;
}

function readCrashFile() {
  const paths = ObjC.classes.NSSearchPathForDirectoriesInDomains(9, 1, true);
  if (!paths || paths.count() === 0) return { error: 'no Documents' };
  const doc = paths.objectAtIndex_(0);
  const path = doc.stringByAppendingPathComponent_('legado_debug_crash.txt');
  const fm = ObjC.classes.NSFileManager.defaultManager();
  if (!fm.fileExistsAtPath_(path)) return { path: path.toString(), exists: false };
  const data = ObjC.classes.NSString.stringWithContentsOfFile_encoding_error_(path, 4, NULL);
  return { path: path.toString(), exists: true, content: data ? data.toString() : '' };
}

rpc.exports = {
  dumpreader: function () {
    return collectReaderDump();
  },
  refresh: function () {
    return refreshReader();
  },
  crash: function () {
    return readCrashFile();
  }
};
