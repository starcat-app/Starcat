/**
 * 第 7 章 assess v2 —— 评估与探索（4 步合并版）。
 *
 * 旧版把截图压暗当背景板、前景叠假仪表盘 —— 观众看到的是"画的"不是
 * "真的"。v2 反转：三张真截图（Health / OpenSSF / CodeFlow）各占一步
 * 主角位，配一条 accent 扫描线表达"评估中"；探索入口一步纯排版收尾。
 *
 * 约束：颜色/字体只走 token；动画 ≤ 各步口播（~6s / ~5s / ~7s / ~5s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./Assess.css";

const HEALTH_AXES = ["活跃度", "维护", "风险"] as const;

const EXPLORE_ENTRIES = ["发现", "趋势", "热门", "新发布", "周刊"] as const;

/** 评估扫描线：从左到右扫过截图一次，呼应「打分」动作。 */
function ScanLine({ delay }: { delay: number }) {
  return <span className="as-scan" style={{ animationDelay: `${delay}ms` }} aria-hidden />;
}

export default function Assess({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="as-scene scene-pad as-center" key={step}>
        <div className="as-kicker">Repo Health</div>
        <figure className="as-shot as-shot-wipe">
          <img
            className="as-shot-img"
            src="/assess/health.webp"
            alt="Repo Health 评分"
          />
          <ScanLine delay={1400} />
          <div className="as-axes">
            {HEALTH_AXES.map((label, i) => (
              <span
                key={label}
                className="as-axis"
                style={{ animationDelay: `${1800 + i * 500}ms` }}
              >
                {label}
              </span>
            ))}
          </div>
        </figure>
        <p className="as-cap serif-cn">汇总成分数，一眼判断值不值得跟</p>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="as-scene scene-pad as-center" key={step}>
        <div className="as-kicker">公开安全评分 · 冷却期刷新</div>
        <h1 className="as-title serif-it">
          OpenSSF <span>Scorecard</span>
        </h1>
        <figure className="as-shot as-shot-wipe">
          <img
            className="as-shot-img"
            src="/assess/openssf.webp"
            alt="OpenSSF Scorecard 雷达图"
          />
          <ScanLine delay={1200} />
        </figure>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="as-scene scene-pad as-center" key={step}>
        <div className="as-kicker">不离开 App · 依赖与调用链路</div>
        <h1 className="as-title serif-it">CodeFlow</h1>
        {/* 与 step1 区分：不用扫描线，改用推镜落定（镜头沉进图谱） */}
        <figure className="as-shot as-shot-wipe as-flow">
          <img
            className="as-shot-img as-img-settle"
            src="/assess/codeflow.webp"
            alt="内置代码图谱"
          />
        </figure>
      </div>
    );
  }

  if (step === 3) {
    return (
      <div className="as-scene scene-pad as-center" key={step}>
        <div className="as-kicker">侧边栏</div>
        <div className="as-explore">
          {EXPLORE_ENTRIES.map((name, i) => (
            <span
              key={name}
              className="as-entry"
              style={{ animationDelay: `${250 + i * 280}ms` }}
            >
              {name}
            </span>
          ))}
        </div>
      </div>
    );
  }

  return null;
}
