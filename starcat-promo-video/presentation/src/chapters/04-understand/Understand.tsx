/**
 * 第 4 章 understand v2 —— 理解仓库（4 步合并版）。
 *
 * 三张真截图各当一步主角：AI摘要（三问 chip 压图）→ 私有笔记+缓存提示排版
 * （旧摘要图缩小挂角）→ AI翻译（整卡）→ AI对话（整卡 + 上下文锚）。
 * 截图里是哪个仓库就让它当哪个仓库 —— 画面不再硬贴 run-llama 名字与截图
 * 内容打架；口播的「那个 RAG 库」由观众自行对应。
 *
 * 约束：颜色/字体只走 token；动画 ≤ 各步口播（最短 step3 ~6s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./Understand.css";

/** 口播念「做什么 / 解决什么 / 技术栈」，chip 只留中性标签，答案以截图为准。 */
const TRIO_LABELS = ["做什么", "解决什么", "技术栈"] as const;

export default function Understand({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="un-scene scene-pad un-center" key={step}>
        <div className="un-repo-line">
          <span className="un-read-tag">AI 已读完 README · 中文结构化摘要</span>
        </div>
        <figure className="un-shot un-shot-wipe">
          <img
            className="un-shot-img"
            src="/understand/summary.webp"
            alt="AI 结构化摘要"
          />
          <div className="un-trio">
            {TRIO_LABELS.map((label, i) => (
              <article
                key={label}
                className="un-field"
                style={{ animationDelay: `${1800 + i * 700}ms` }}
              >
                <h2 className="un-field-label serif-cn">{label}</h2>
              </article>
            ))}
          </div>
        </figure>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="un-scene scene-pad un-notes-step" key={step}>
        <div className="un-note-col">
          <div className="un-note-sheet card">
            <span className="un-note-caret" aria-hidden />
            <span className="un-note-label">私有笔记</span>
          </div>
          <h1 className="un-note-slogan serif-cn">每个仓库一份</h1>
        </div>
        <div className="un-cache-col">
          <div className="un-cache card">
            <div className="un-lamp" aria-hidden>
              <span className="un-lamp-core" />
            </div>
            <p className="un-cache-label serif-cn">摘要按仓库缓存</p>
          </div>
          <div className="un-change">README 变更 · 提醒重新生成</div>
        </div>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="un-scene scene-pad un-center" key={step}>
        <figure className="un-shot un-shot-wipe">
          <img
            className="un-shot-img"
            src="/understand/translate.webp"
            alt="README 翻译对照"
          />
        </figure>
        <div className="un-quota-tag">命中缓存 · 不扣配额</div>
      </div>
    );
  }

  if (step === 3) {
    return (
      <div className="un-scene scene-pad un-center" key={step}>
        <div className="un-chat-anchor card">
          <span className="serif-cn">多轮对话</span>
          <span className="un-anchor-label">上下文 · 锚定当前仓库</span>
        </div>
        <figure className="un-shot un-shot-wipe">
          <img
            className="un-shot-img"
            src="/understand/chat.webp"
            alt="对当前仓库的多轮对话"
          />
        </figure>
      </div>
    );
  }

  return null;
}
