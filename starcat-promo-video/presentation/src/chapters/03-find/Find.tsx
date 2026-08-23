/**
 * 第 3 章 find v2 —— 找回（4 步合并版）。
 *
 * 一张真截图（sc-全局搜索）讲满整章：step0 整卡揭开 + 四索引字段 lockup；
 * step1 推近搜索区 + 「本机·毫秒级·不走云」角标；step2 推近结果区 + 开场
 * 那个 RAG 库的第一页回扣浮层；step3 图缩小让位给 Pro 语义搜索大字。
 * 术语（BM25/RRF）降级为 mono 小字，口播只讲人话。
 *
 * 约束：颜色/字体只走 token；动画 ≤ 各步口播（最短 step2 ~5s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./Find.css";

function FieldLockup() {
  return (
    <h1 className="fd-lockup">
      <span className="serif-cn">仓库名</span>
      <i className="fd-mid" aria-hidden />
      <span className="serif-cn">描述</span>
      <i className="fd-mid" aria-hidden />
      <span className="serif-it">Topics</span>
      <i className="fd-mid" aria-hidden />
      <span className="serif-cn">笔记</span>
    </h1>
  );
}

export default function Find({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="fd-scene scene-pad fd-center" key={step}>
        <FieldLockup />
        <figure className="fd-shot fd-shot-wipe">
          <img
            className="fd-shot-img"
            src="/find/search.webp"
            alt="Starcat 全局搜索"
          />
        </figure>
        <p className="fd-index-note">全部建进全文索引</p>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="fd-scene" key={step}>
        <figure className="fd-shot fd-shot-zoom-top">
          <img
            className="fd-shot-img fd-img-top"
            src="/find/search.webp"
            alt="搜索框与组合过滤"
          />
          <span className="fd-callout fd-callout-search" aria-hidden />
          <span className="fd-callout-label">自然语言 · 组合过滤</span>
        </figure>
        <span className="fd-corner-tag">本机 · 毫秒级 · 不走云</span>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="fd-scene" key={step}>
        <figure className="fd-shot fd-shot-zoom-result">
          <img
            className="fd-shot-img fd-img-result"
            src="/find/search.webp"
            alt="搜索结果第一页"
          />
        </figure>
        <div className="fd-first-hit serif-cn">就在第一页</div>
      </div>
    );
  }

  if (step === 3) {
    return (
      <div className="fd-scene scene-pad fd-split-step" key={step}>
        <div className="fd-semantic">
          <div className="fd-sem-mark serif-cn">语义搜索</div>
          <h1 className="fd-semantic-h serif-cn">按意图找</h1>
          <p className="fd-semantic-sub">不挑关键词</p>
          <p className="fd-fusion mono">BM25 × Embedding × RRF</p>
        </div>
        <figure className="fd-shot fd-shot-side">
          <img
            className="fd-shot-img"
            src="/find/search.webp"
            alt="语义搜索结果"
          />
        </figure>
      </div>
    );
  }

  return null;
}
