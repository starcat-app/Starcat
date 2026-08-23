/**
 * 第 6 章 organize v2 —— Release 订阅与智能集合（3 步合并版）。
 *
 * step0 把「订阅通知 / 平台过滤 / 复制链接」并成一屏排版组；
 * step1/2 用真截图 sc-智能集合 当主角：先高亮口播点名的两枚集合，
 * 再让其余四枚以芯片行补齐 —— 不把集合名当清单逐个入场。
 *
 * 约束：颜色/字体只走 token；动画 ≤ 各步口播（~8s / ~8s / ~6s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./Organize.css";

const MORE_COLLECTIONS = [
  { name: "High Value", gloss: "高价值" },
  { name: "No Tags", gloss: "无标签" },
  { name: "Using", gloss: "正在用" },
  { name: "Recently Active", gloss: "最近活跃" },
] as const;

/** 几何通知：钟体 path + 角标方点，避免 emoji 铃铛。 */
function NoticeMark() {
  return (
    <svg className="og-bell" viewBox="0 0 96 96" aria-hidden>
      <circle className="og-bell-ring" cx="48" cy="44" r="38" />
      <path
        className="og-bell-body"
        d="M48 12 C32 12 24 26 24 40 V50 L14 66 H82 L72 50 V40 C72 26 64 12 48 12 Z"
      />
      <path className="og-bell-clapper" d="M36 72 Q48 86 60 72" />
      <rect className="og-bell-pip" x="66" y="14" width="14" height="14" />
    </svg>
  );
}

export default function Organize({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="og-scene scene-pad og-release-step" key={step}>
        <div className="og-release-left">
          <NoticeMark />
          <article className="card og-note">
            <p className="og-kicker">Release · 订阅</p>
            <h1 className="og-note-hero serif-cn">新版本</h1>
            <p className="og-note-sub">第一时间通知</p>
          </article>
        </div>
        <div className="og-release-right">
          <p className="og-kicker">安装包 · 按平台过滤</p>
          <div className="og-chips">
            <span className="og-chip is-on">macOS</span>
            <span className="og-chip is-off">Linux</span>
            <span className="og-chip is-off">Windows</span>
            <span className="og-chip is-on">.dmg</span>
            <span className="og-chip is-off">.zip</span>
          </div>
          <div className="og-copyline">
            <span className="og-copy serif-it">Copy</span>
            <span className="og-copy-url">github.com/apple/swift/releases/…</span>
          </div>
        </div>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="og-scene scene-pad og-center" key={step}>
        <figure className="og-shot og-shot-wipe">
          <img
            className="og-shot-img"
            src="/organize/collections.webp"
            alt="智能集合"
          />
          <div className="og-hot">
            <div className="og-hot-item">
              <h2 className="og-hot-name serif-it">Needs Review</h2>
              <p className="og-hot-gloss serif-cn">没看过的</p>
            </div>
            <div className="og-hot-rule" aria-hidden />
            <div className="og-hot-item">
              <h2 className="og-hot-name serif-it">Unmaintained</h2>
              <p className="og-hot-gloss serif-cn">一年没动静</p>
            </div>
          </div>
        </figure>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="og-scene scene-pad og-center" key={step}>
        <figure className="og-shot og-shot-mini og-shot-wipe">
          <img
            className="og-shot-img"
            src="/organize/collections.webp"
            alt="智能集合全览"
          />
        </figure>
        <div className="og-more">
          {MORE_COLLECTIONS.map((c, i) => (
            <div
              key={c.name}
              className="og-more-item"
              style={{ animationDelay: `${700 + i * 320}ms` }}
            >
              <h2 className="og-more-name serif-it">{c.name}</h2>
              <p className="og-more-gloss serif-cn">{c.gloss}</p>
            </div>
          ))}
        </div>
        <p className="og-alone serif-cn">都能单独列出来</p>
      </div>
    );
  }

  return null;
}
