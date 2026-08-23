/**
 * 第 5 章 tags v2 —— 建议，不是替你写（3 步合并版）。
 *
 * 无官方截图：排版演「推荐+置信度+分类归并 → 硬规则大字 → 确认后写入」。
 * 旧 step1（14 分类独占一步）并入 step0 角标；旧确认按钮改为已确认印章态
 * —— 自动录屏点不了按钮，画面直接呈现「你点了确认之后」的世界。
 *
 * 约束：颜色/字体只走 token；动画 ≤ 各步口播（~8s / ~4s / ~5s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./Tags.css";

/** 候选标签名来自 llama_index 的真实归类，不挂百分比数字。 */
const CANDIDATES = ["RAG", "LLM", "Python", "Data", "Library"] as const;

/** 确认后落入仓库卡的三枚——只贴最靠前的，避免卡面挤满。 */
const APPLIED = ["RAG", "LLM", "Python"] as const;

export default function Tags({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="tg-scene scene-pad tg-center" key={step}>
        <div className="tg-kicker">AI 推荐 · 尚未写入</div>
        <ul className="tg-cands">
          {CANDIDATES.map((name, i) => (
            <li
              key={name}
              className="tg-cand"
              style={{ animationDelay: `${300 + i * 260}ms` }}
            >
              <span className="tg-cand-name">{name}</span>
              <span className="tg-track" aria-hidden>
                <span
                  className="tg-fill"
                  style={{ animationDelay: `${600 + i * 260}ms` }}
                />
              </span>
            </li>
          ))}
        </ul>
        <div className="tg-meta">
          <span className="tg-fourteen hero-num">14</span>
          <span className="tg-fourteen-cap serif-cn">套预设分类 · 同义自动归并</span>
          <span className="tg-syn-pair">
            <span className="tg-syn-tag">LLM</span>
            <i className="tg-syn-link" aria-hidden />
            <span className="tg-syn-tag">大模型</span>
          </span>
        </div>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="tg-scene scene-pad tg-center" key={step}>
        <div className="tg-kicker">产品硬规则</div>
        <h1 className="tg-verdict serif-cn">AI 只给建议</h1>
        <p className="tg-verdict-sub serif-cn">标签不经确认绝不自动应用</p>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="tg-scene scene-pad tg-center" key={step}>
        <article className="card tg-repo">
          <div className="tg-repo-full">run-llama / llama_index</div>
          <p className="tg-repo-desc serif-it">
            LlamaIndex is a data framework for your LLM applications.
          </p>
          <div className="tg-slots">
            {APPLIED.map((name, i) => (
              <span
                key={name}
                className="tg-on"
                style={{ animationDelay: `${1400 + i * 240}ms` }}
              >
                {name}
              </span>
            ))}
          </div>
          <span className="tg-seal serif-cn">已确认</span>
        </article>
        <p className="tg-sqlite">写入本地 SQLite</p>
      </div>
    );
  }

  return null;
}
