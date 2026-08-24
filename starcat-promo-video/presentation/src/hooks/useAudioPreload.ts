import { useEffect } from "react";
import type { ChapterDef } from "../registry/types";

/**
 * Module-level cache: original URL → blob object URL.
 * Lives outside React so remounts / mode switches reuse warmed audio.
 */
const cache = new Map<string, string>();

/** Return the zero-latency blob URL for `url`, or the original if not yet warm. */
export function cachedAudioSrc(url: string): string {
  return cache.get(url) ?? url;
}

function preloadOne(url: string): void {
  if (cache.has(url)) return;
  fetch(url)
    .then((res) => (res.ok ? res.blob() : null))
    .then((blob) => {
      // Last writer wins is fine — content for a given URL is immutable.
      if (blob) cache.set(url, URL.createObjectURL(blob));
    })
    .catch(() => {
      /* Missing file: useAudioPlayer handles per-step error/fallback. */
    });
}

/**
 * Warm every step's mp3 into memory BEFORE playback starts.
 *
 * Why: per-step `new Audio(src)` used to load from the dev server while
 * CSS entry animations already ran → voice started hundreds of ms late and
 * drift varied per step (the 声画不同步 root cause besides mp3 silence).
 * Total payload is only ~1-2 MB, so fetching all segments up front makes
 * `play()` start within a frame of the step switch.
 */
export function useAudioPreload(chapters: ChapterDef[]): void {
  useEffect(() => {
    for (const ch of chapters) {
      ch.narrations.forEach((text, i) => {
        if (!text) return; // silent steps have no file
        preloadOne(`${import.meta.env.BASE_URL}audio/${ch.id}/${i + 1}.mp3`);
      });
    }
  }, [chapters]);
}
