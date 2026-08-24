import { useEffect, useRef } from "react";

export type PlaybackMode = "manual" | "audio" | "auto";

interface Options {
  /** Audio file path. `null` = no audio for this step (silent). */
  src: string | null;
  /** `manual` = no playback. `audio` = play but don't auto-advance.
   *  `auto` = play and auto-advance when finished. */
  mode: PlaybackMode;
  /** Small breathing pad (ms) after audio finishes before advancing,
   *  in `auto` mode. Default 200ms. Set to 0 if mp3 already has trailing
   *  silence. */
  trailMs?: number;
  /** Fallback duration (ms) for `auto` mode when the audio file is missing
   *  or fails to play. Typically computed from text length. */
  estimateFallbackMs?: number;
  /** Called when `auto` mode determines the step is finished. */
  onAutoAdvance: () => void;
  /** Has the user started auto playback? (Browsers block autoplay until
   *  the page receives a user gesture; the AutoStartGate flips this.) */
  autoStarted: boolean;
  /** Fired when the step's audio is actually audible (`playing` event), or
   *  immediately when there is nothing to wait for (manual mode, no src,
   *  gate not released) or waiting became pointless (error / safety cap).
   *  App uses this to unfreeze the scene's CSS animations → 帧级声画锁. */
  onStart?: () => void;
}

/**
 * Per-step audio playback for the presentation.
 *
 * Manages a single hidden `<audio>` element. Switches `src` whenever the
 * current step changes.
 *
 * In `auto` mode:
 *   • Audio file present → advance `trailMs` after the audio's `ended` event.
 *   • Audio file missing / blocked / src = null → advance after
 *     `estimateFallbackMs` (so previews and silent steps still work).
 *
 * Audio playback is the sole driver of step duration — there is intentionally
 * no "minimum hold" knob. If a chapter's visual animation needs more time,
 * the chapter should write longer narration, split the step, or speed the
 * animation up. This keeps Auto-mode behavior trivially predictable.
 */
export function useAudioPlayer({
  src,
  mode,
  trailMs = 200,
  estimateFallbackMs = 1500,
  onAutoAdvance,
  autoStarted,
  onStart,
}: Options) {
  const audioRef = useRef<HTMLAudioElement | null>(null);
  // Latest callback refs so timers don't capture stale closures.
  const onAdvanceRef = useRef(onAutoAdvance);
  onAdvanceRef.current = onAutoAdvance;
  const onStartRef = useRef(onStart);
  onStartRef.current = onStart;

  useEffect(() => {
    const prev = audioRef.current;
    if (prev) {
      prev.pause();
      prev.removeAttribute("src");
      prev.load();
      audioRef.current = null;
    }

    if (mode === "manual") return;
    if (mode === "auto" && !autoStarted) return;

    let advanced = false;
    let started = false;
    let timer: number | null = null;
    let startTimer: number | null = null;

    const markStarted = () => {
      if (started) return;
      started = true;
      if (startTimer != null) clearTimeout(startTimer);
      onStartRef.current?.();
    };

    const advanceAfter = (ms: number) => {
      if (mode !== "auto" || advanced) return;
      timer = window.setTimeout(() => {
        if (advanced) return;
        advanced = true;
        onAdvanceRef.current();
      }, Math.max(0, ms));
    };

    if (src) {
      const audio = new Audio(src);
      audioRef.current = audio;
      audio.preload = "auto";

      // `playing` = samples actually reaching the output — the only honest
      // sync anchor for visuals. (`canplay`/`loadstart` fire too early.)
      audio.addEventListener("playing", markStarted);
      audio.addEventListener("ended", () => advanceAfter(trailMs));
      audio.addEventListener("error", () => {
        // Audio file missing or undecodable — release visuals, use estimate.
        markStarted();
        if (mode === "auto") advanceAfter(estimateFallbackMs);
      });

      audio.play().catch((err) => {
        // Autoplay blocked (rare, AutoStartGate should prevent this) or
        // file missing — fall back to estimate in auto mode.
        console.warn("audio play failed:", err);
        markStarted();
        if (mode === "auto") advanceAfter(estimateFallbackMs);
      });

      // Safety cap: never freeze the scene if `playing` is slow to arrive
      // (slow decode, odd codec path). Slightly-early beats stuck frame.
      startTimer = window.setTimeout(markStarted, 800);
    } else if (mode === "auto") {
      // No audio for this step (silent / empty narration) — use estimate.
      markStarted();
      advanceAfter(estimateFallbackMs);
    }

    return () => {
      advanced = true;
      started = true;
      if (timer != null) clearTimeout(timer);
      if (startTimer != null) clearTimeout(startTimer);
      const a = audioRef.current;
      if (a) {
        a.pause();
        a.removeAttribute("src");
        a.load();
        audioRef.current = null;
      }
    };
  }, [src, mode, trailMs, estimateFallbackMs, autoStarted]);
}
