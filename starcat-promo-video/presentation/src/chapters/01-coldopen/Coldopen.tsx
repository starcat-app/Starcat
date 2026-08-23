/**
 * 第 1 章 coldopen v2 —— Star 收藏夹吃灰（5 步合并版）。
 *
 * 节拍变化：旧 8 步的碎拍（空结果 / 理由消失）并入相邻步，每步一个完整
 * 想法。主导动作按 step 换：打字机 → 模糊锐化 → 理由蒸发 → 对切开 →
 * 时间线收束成对仗 takeover。禁止全章共用一种 fade。
 * 颜色和字体家族只引用 token；动画时长压在各步口播之内。
 */
import { MaskReveal } from "../../components/MaskReveal";
import type { ChapterStepProps } from "../../registry/types";
import "./Coldopen.css";

/** 公开仓库名，只当时间线纹理，不挂假 star 数。 */
const STAR_RIVER = [
  "langchain-ai/langchain",
  "run-llama/llama_index",
  "ggerganov/llama.cpp",
  "openai/whisper",
  "facebook/react",
  "vercel/next.js",
  "microsoft/vscode",
  "apple/swift",
  "kubernetes/kubernetes",
  "torvalds/linux",
  "huggingface/transformers",
  "denoland/deno",
  "rust-lang/rust",
  "golang/go",
  "neovim/neovim",
  "obsidianmd/obsidian-releases",
];

function SearchField({ query }: { query: string }) {
  return (
    <div className="cd-search">
      <span className="cd-search-kicker">github stars · local</span>
      <div className="cd-search-bar">
        <span className="cd-search-query">{query}</span>
        <span className="cd-caret" aria-hidden />
      </div>
    </div>
  );
}

function RepoCard({ reasonGone }: { reasonGone?: boolean }) {
  return (
    <article className="card cd-repo">
      <div className="cd-repo-full">run-llama / llama_index</div>
      <p className="cd-repo-desc">
        LlamaIndex is a data framework for your LLM applications.
      </p>
      <div className={`cd-reason ${reasonGone ? "is-gone" : ""}`}>
        <span className="cd-reason-label">收藏理由</span>
        <span className="cd-reason-text">{reasonGone ? "" : "—"}</span>
      </div>
    </article>
  );
}

function StarRiver({ dimmed }: { dimmed?: boolean }) {
  const loop = [...STAR_RIVER, ...STAR_RIVER];
  return (
    <div className={`cd-river ${dimmed ? "is-dim" : ""}`} aria-hidden>
      <div className="cd-river-col cd-river-a">
        {loop.map((name, i) => (
          <span key={`a-${i}`}>{name}</span>
        ))}
      </div>
      <div className="cd-river-col cd-river-b">
        {loop.map((name, i) => (
          <span key={`b-${i}`}>{name}</span>
        ))}
      </div>
    </div>
  );
}

export default function Coldopen({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="cd-scene scene-pad" key={step}>
        <SearchField query="RAG" />
        <div className="cd-timer serif-cn">20 分钟</div>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="cd-scene scene-pad cd-scene-center" key={step}>
        <div className="cd-kicker">还是没翻到</div>
        <div className="cd-thousand hero-num">1000+</div>
        <div className="cd-thousand-sub serif-cn">Stars</div>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="cd-scene scene-pad cd-scene-center" key={step}>
        <div className="cd-kicker">三个月前点开</div>
        <RepoCard reasonGone />
      </div>
    );
  }

  if (step === 3) {
    return (
      <div className="cd-scene scene-pad" key={step}>
        <div className="cd-split">
          <div className="cd-split-pane">
            <div className="cd-kicker">标签</div>
            <div className="cd-tags">
              <span className="cd-tag" />
              <span className="cd-tag" />
              <span className="cd-tag" />
            </div>
            <p className="cd-split-line serif-cn">懒得打</p>
          </div>
          <div className="cd-split-rule" />
          <div className="cd-split-pane">
            <div className="cd-kicker">更新</div>
            <div className="card cd-tweet">
              <div className="cd-tweet-user">somebody on X</div>
              <p className="cd-tweet-body">llama_index released.</p>
            </div>
            <p className="cd-split-line serif-cn">从推文里才知道</p>
          </div>
        </div>
      </div>
    );
  }

  if (step === 4) {
    return (
      <div className="cd-scene" key={step}>
        <StarRiver />
        <div className="cd-finale scene-pad">
          <MaskReveal show duration={900}>
            <span className="cd-finale-cap serif-cn">一条往下滚的时间线</span>
          </MaskReveal>
          <h1 className="cd-pair serif-cn">
            <span className="cd-pair-a">收藏很多</span>
            <span className="cd-pair-b">能用的很少</span>
          </h1>
        </div>
      </div>
    );
  }

  return null;
}
