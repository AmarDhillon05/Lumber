// Shown instead of crashing when JavaScript fails: at start-up (a module
// throwing while it loads), during render, or as an uncaught fatal error.
// Release builds otherwise close the app with no message, so this puts the
// error on screen with a Share button. Deliberately depends only on React
// Native itself, so it still works when the rest of the app failed to load.

import { Component, createElement, useEffect, useState, type ReactNode } from 'react';
import { Pressable, ScrollView, Share, StyleSheet, Text, View } from 'react-native';

export interface CrashInfo {
  message: string;
  stack?: string;
  where: string;
  at: string;
}

export function toCrashInfo(e: unknown, where: string): CrashInfo {
  const err = e instanceof Error ? e : new Error(String(e));
  return { message: `${err.name}: ${err.message}`, stack: err.stack, where, at: new Date().toISOString() };
}

let current: CrashInfo | null = null;
const listeners = new Set<(c: CrashInfo | null) => void>();

export function reportCrash(info: CrashInfo): void {
  current = info;
  listeners.forEach((l) => l(info));
}

// Replace React Native's global handler: a fatal JS error shows the crash
// screen instead of terminating the app. Non-fatal ones keep the default.
export function installCrashHandler(): void {
  const g = globalThis as unknown as {
    ErrorUtils?: {
      getGlobalHandler(): (e: unknown, fatal?: boolean) => void;
      setGlobalHandler(h: (e: unknown, fatal?: boolean) => void): void;
    };
  };
  const utils = g.ErrorUtils;
  if (!utils) return;
  const fallback = utils.getGlobalHandler();
  utils.setGlobalHandler((e, fatal) => {
    if (fatal) reportCrash(toCrashInfo(e, 'uncaught error'));
    else fallback(e, fatal);
  });
}

class Boundary extends Component<{ children: ReactNode }, { crashed: boolean }> {
  state = { crashed: false };
  static getDerivedStateFromError() {
    return { crashed: true };
  }
  componentDidCatch(e: unknown) {
    reportCrash(toCrashInfo(e, 'while drawing a screen'));
  }
  render() {
    return this.state.crashed ? null : this.props.children;
  }
}

export function CrashScreen({ info, onDismiss }: { info: CrashInfo; onDismiss?: () => void }) {
  const text = `Lumber crashed ${info.where} (${info.at})\n\n${info.message}\n\n${info.stack ?? ''}`;
  return createElement(
    View,
    { style: s.root },
    createElement(Text, { style: s.title }, 'Lumber hit an error'),
    createElement(Text, { style: s.sub }, `${info.where}. Share this with the developer.`),
    createElement(
      ScrollView,
      { style: s.box, contentContainerStyle: { padding: 12 } },
      createElement(Text, { style: s.msg, selectable: true }, info.message),
      createElement(Text, { style: s.stack, selectable: true }, info.stack ?? ''),
    ),
    createElement(
      View,
      { style: s.row },
      createElement(
        Pressable,
        { style: [s.btn, s.primary], onPress: () => Share.share({ message: text }).catch(() => {}) },
        createElement(Text, { style: s.btnText }, 'Share'),
      ),
      onDismiss
        ? createElement(Pressable, { style: s.btn, onPress: onDismiss }, createElement(Text, { style: s.btnText }, 'Try again'))
        : null,
    ),
  );
}

// Wraps the app: shows CrashScreen when anything is reported.
export function withCrashScreen(App: () => ReactNode) {
  return function CrashGate() {
    const [crash, setCrash] = useState<CrashInfo | null>(current);
    const [attempt, setAttempt] = useState(0);
    useEffect(() => {
      listeners.add(setCrash);
      return () => {
        listeners.delete(setCrash);
      };
    }, []);
    if (crash) {
      return createElement(CrashScreen, {
        info: crash,
        onDismiss: () => {
          current = null;
          setCrash(null);
          setAttempt((n) => n + 1);
        },
      });
    }
    return createElement(Boundary, { key: attempt, children: createElement(App) });
  };
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#0e0e16', paddingTop: 64, paddingHorizontal: 16, paddingBottom: 32 },
  title: { color: '#f3f3fa', fontSize: 22, fontWeight: '700' },
  sub: { color: '#9b9bb4', fontSize: 14, marginTop: 6, marginBottom: 12 },
  box: { flex: 1, backgroundColor: '#171724', borderRadius: 12, borderWidth: 1, borderColor: '#2b2b3d' },
  msg: { color: '#fda4af', fontSize: 15, fontWeight: '600', marginBottom: 10 },
  stack: { color: '#d3d3e3', fontSize: 11, fontFamily: 'Menlo' },
  row: { flexDirection: 'row', gap: 10, marginTop: 14 },
  btn: { flex: 1, paddingVertical: 13, borderRadius: 12, alignItems: 'center', backgroundColor: '#171724', borderWidth: 1, borderColor: '#2b2b3d' },
  primary: { backgroundColor: '#8b5cf6', borderColor: '#8b5cf6' },
  btnText: { color: '#ffffff', fontSize: 15, fontWeight: '600' },
});
