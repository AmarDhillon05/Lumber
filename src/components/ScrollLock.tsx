// Lets a draggable control (knob, slider) inside a ScrollView stop the page
// from scrolling while it's being touched. On iOS the UIScrollView pan gesture
// otherwise wins over a JS PanResponder as soon as the finger moves vertically,
// so the control locks scrolling on touch start and unlocks on release.
//
// Locks are counted (two fingers on two knobs) and released on unmount, so a
// lost release event can't leave the page stuck. Outside a LockableScrollView
// the hook is a no-op.

import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ComponentProps } from 'react';
import { ScrollView } from 'react-native';

type Ctx = { acquire: () => () => void };

const ScrollLockContext = createContext<Ctx | null>(null);

// A ScrollView whose scrolling is disabled while any child holds a lock.
export function LockableScrollView({ scrollEnabled = true, ...props }: ComponentProps<typeof ScrollView>) {
  const [locks, setLocks] = useState(0);
  const ctx = useMemo<Ctx>(
    () => ({
      acquire: () => {
        let held = true;
        setLocks((n) => n + 1);
        return () => {
          if (!held) return;
          held = false;
          setLocks((n) => Math.max(0, n - 1));
        };
      },
    }),
    [],
  );
  return (
    <ScrollLockContext.Provider value={ctx}>
      <ScrollView {...props} scrollEnabled={scrollEnabled && locks === 0} />
    </ScrollLockContext.Provider>
  );
}

// Returns setScrollLocked(bool) for one control. Idempotent; unlocks on unmount.
export function useScrollLock(): (locked: boolean) => void {
  const ctx = useContext(ScrollLockContext);
  const release = useRef<(() => void) | null>(null);

  const setScrollLocked = useCallback(
    (locked: boolean) => {
      if (locked) {
        if (!release.current && ctx) release.current = ctx.acquire();
      } else {
        release.current?.();
        release.current = null;
      }
    },
    [ctx],
  );

  useEffect(
    () => () => {
      release.current?.();
      release.current = null;
    },
    [ctx],
  );

  return setScrollLocked;
}
