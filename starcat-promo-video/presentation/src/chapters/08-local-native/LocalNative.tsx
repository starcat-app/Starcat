/**
 * 第 8 章 local-native v2 —— 数据在你的 Mac 上（4 步合并版）。
 *
 * step0 把「Mac 剪影 + GRDB/SQLite + 离线」并成一屏空间叙事；step1 把
 * 「缓存可重建 | 用户数据不能丢 | CloudKit 分流 | Keychain 锁」合成一块
 * 数据边界板；step2 用真截图 sc-AI服务配置 当 BYOK 主角，五家 provider
 * 名单压图；step3 大字收束。四家模型名不再各占一步 stagger。
 *
 * 约束：颜色/字体只走 token；动画 ≤ 各步口播（~6s / ~9s / ~8s / ~3s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./LocalNative.css";

/** article §5：用户数据不能丢的三件套，口播点名、画面要挂上。 */
const KEEP = ["标签", "笔记", "状态"] as const;

const PROVIDERS = ["自建代理", "Gemini", "DeepSeek", "OpenAI 兼容", "Ollama"] as const;

function MacSilhouette() {
  return (
    <svg className="ln-mac" viewBox="0 0 800 500" aria-hidden>
      <rect className="ln-mac-lid" x="120" y="16" width="560" height="348" rx="12" />
      <rect className="ln-mac-glass" x="142" y="38" width="516" height="304" />
      <rect className="ln-mac-catch" x="142" y="38" width="516" height="304" />
      <rect className="ln-mac-cam" x="394" y="22" width="12" height="8" />
      <rect className="ln-mac-hinge" x="120" y="364" width="560" height="12" />
      <path className="ln-mac-deck" d="M40 376 H760 L800 492 H0 Z" />
      <rect className="ln-mac-slot" x="340" y="376" width="120" height="8" />
    </svg>
  );
}

/** 数据点落到屏幕里。落点错开用 CSS nth-child，不用 JS 定时器。 */
function DataDots() {
  return (
    <div className="ln-dots" aria-hidden>
      {Array.from({ length: 6 }, (_, i) => (
        <span key={i} className="ln-dot" />
      ))}
    </div>
  );
}

function KeyLock() {
  return (
    <svg className="ln-lock" viewBox="0 0 96 128" aria-hidden>
      <path
        className="ln-lock-shackle"
        d="M24 58 V40 A24 24 0 0 1 72 40 V58"
      />
      <rect className="ln-lock-body" x="14" y="58" width="68" height="58" rx="6" />
      <circle className="ln-lock-hole" cx="48" cy="86" r="7" />
    </svg>
  );
}

/** CloudKit 分流板：用户数据到云、缓存被截、钥匙进锁 —— 同一拍同屏。 */
function SyncBoard() {
  return (
    <div className="ln-sync">
      <div className="ln-sync-row ln-sync-ok">
        <span className="ln-sync-src">用户数据</span>
        <svg className="ln-sync-line" viewBox="0 0 320 24" aria-hidden>
          <line className="ln-sync-draw" x1="0" y1="12" x2="320" y2="12" />
        </svg>
        <span className="ln-sync-dst serif-it">CloudKit</span>
      </div>
      <div className="ln-sync-row ln-sync-block">
        <span className="ln-sync-src">仓库缓存</span>
        <svg className="ln-sync-line" viewBox="0 0 320 24" aria-hidden>
          <line className="ln-sync-halt" x1="0" y1="12" x2="168" y2="12" />
          <line className="ln-sync-x-a" x1="176" y1="4" x2="196" y2="20" />
          <line className="ln-sync-x-b" x1="196" y1="4" x2="176" y2="20" />
        </svg>
        <span className="ln-sync-dst">不上云</span>
      </div>
      <div className="ln-sync-row ln-sync-key">
        <span className="ln-sync-src">Token · AI Key</span>
        <KeyLock />
        <span className="ln-sync-dst serif-it">Keychain</span>
      </div>
    </div>
  );
}

export default function LocalNative({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="ln-scene scene-pad ln-center" key={step}>
        <div className="ln-kicker">本地优先 · GRDB.swift</div>
        <div className="ln-mac-wrap">
          <MacSilhouette />
          <DataDots />
        </div>
        <h1 className="ln-hero serif-cn">GRDB + SQLite</h1>
        <span className="ln-offline">离线也能打开</span>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="ln-scene scene-pad ln-boundary" key={step}>
        <div className="ln-split">
          <div className="ln-col">
            <div className="ln-kicker">仓库缓存</div>
            <h2 className="ln-col-hero serif-cn">可重建</h2>
            <p className="ln-col-cap">丢了能再拉</p>
          </div>
          <div className="ln-cut" aria-hidden />
          <div className="ln-col">
            <div className="ln-kicker">用户数据</div>
            <h2 className="ln-col-hero serif-cn">不能丢</h2>
            <p className="ln-keep">
              {KEEP.map((item) => (
                <span key={item}>{item}</span>
              ))}
            </p>
          </div>
        </div>
        <SyncBoard />
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="ln-scene scene-pad ln-center" key={step}>
        <div className="ln-byok-line">
          <span className="ln-byok-title serif-it">BYOK</span>
          <span className="ln-byok-sub">你的模型，你说了算</span>
        </div>
        <figure className="ln-shot">
          <img
            className="ln-shot-img"
            src="/local/byok.webp"
            alt="AI 服务配置"
          />
        </figure>
        <div className="ln-providers">
          {PROVIDERS.map((name, i) => (
            <span
              key={name}
              className="ln-provider"
              style={{ animationDelay: `${1500 + i * 300}ms` }}
            >
              {name}
            </span>
          ))}
        </div>
      </div>
    );
  }

  if (step === 3) {
    return (
      <div className="ln-scene scene-pad ln-center" key={step}>
        <h1 className="ln-lockup serif-cn">
          你的 Key
          <span className="ln-lockup-slash">/</span>
          你的配额
        </h1>
      </div>
    );
  }

  return null;
}
