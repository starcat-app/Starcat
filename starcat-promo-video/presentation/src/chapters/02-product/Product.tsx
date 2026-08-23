/**
 * 第 2 章 product v2 —— Starcat 是什么（4 步合并版）。
 *
 * 节拍变化：旧 5 步的「SVG 三栏示意」升级为真截图 hero —— 口播讲原生时
 * 主界面整卡揭开，讲本地知识库时镜头推近列表区。套壳名降级为角注划掉，
 * 不再独占一步。四词仍是整行 lockup（口播是一句口号，不拆 stagger）。
 *
 * 约束：颜色/字体只走 token；每步动画 ≤ 该步口播（最短 step0 仅 ~2s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./Product.css";

const SHELLS = ["Electron", "Tauri", "Flutter"] as const;

export default function Product({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="pd-scene scene-pad pd-center" key={step}>
        <img
          className="pd-logo"
          src="/product/logo.png"
          width={240}
          height={240}
          alt="Starcat"
        />
        <h1 className="pd-name serif-cn">Starcat</h1>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="pd-scene scene-pad pd-hero-step" key={step}>
        <figure className="pd-shot">
          <img
            className="pd-shot-img"
            src="/product/banner.webp"
            alt="Starcat 三栏主界面"
          />
        </figure>
        <div className="pd-native-row">
          <span>macOS 原生</span>
          <span className="pd-dot" />
          <span>SwiftUI 三栏</span>
          <span className="pd-dot" />
          <span>Liquid Glass</span>
        </div>
        <ul className="pd-shells-note" aria-label="未采用的跨平台方案">
          {SHELLS.map((name, i) => (
            <li key={name} className={`pd-shell-mini shell-${i}`}>
              <span className="serif-it">{name}</span>
              <span className="pd-strike" aria-hidden />
            </li>
          ))}
        </ul>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="pd-scene" key={step}>
        <div className="pd-zoom-frame">
          <img
            className="pd-zoom-img"
            src="/product/banner.webp"
            alt="Starcat 列表区特写"
          />
        </div>
        <div className="pd-zoom-overlay scene-pad">
          <span className="pd-zoom-tag">local first · offline ready</span>
          <p className="pd-zoom-cap serif-cn">你自己的本地知识库</p>
        </div>
      </div>
    );
  }

  if (step === 3) {
    return (
      <div className="pd-scene scene-pad pd-center" key={step}>
        <div className="pd-kicker">核心价值</div>
        <h1 className="pd-lockup serif-cn">整理 · 理解 · 找回 · 评估</h1>
      </div>
    );
  }

  return null;
}
