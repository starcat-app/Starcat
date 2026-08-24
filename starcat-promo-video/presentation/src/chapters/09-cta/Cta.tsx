/**
 * 第 9 章 cta v3 —— 边界、开源、下载（3 步）。
 *
 * 付费订阅叙事已整体删除：Starcat 完全开源、基础功能免费。
 * step0 平台边界（Direct 包 + 不支持平台划掉）；step1 开源 + 三条获取
 * 路径（本地编译 / App Store / Direct）；step2 logo + 域名收束。
 *
 * 约束：颜色/字体只走 token；动画 ≤ 各步口播（~7s / ~12s / ~6s）。
 */
import type { ChapterStepProps } from "../../registry/types";
import "./Cta.css";

const OUT = ["iOS", "Windows", "Android"] as const;

const GET_PATHS = [
  { name: "本地编译", sub: "源码构建" },
  { name: "App Store", sub: "商店安装" },
  { name: "Direct 下载", sub: "官网直装" },
] as const;

function DirectPack() {
  return (
    <svg className="ct-pack" viewBox="0 0 280 180" aria-hidden>
      <polygon className="ct-pack-stroke ct-pack-lid" points="20,62 140,18 260,62 140,106" />
      <polygon className="ct-pack-stroke" points="20,62 20,128 140,172 140,106" />
      <polygon className="ct-pack-stroke" points="260,62 260,128 140,172 140,106" />
    </svg>
  );
}

export default function Cta({ step }: ChapterStepProps) {
  if (step === 0) {
    return (
      <div className="ct-scene scene-pad ct-center" key={step}>
        <div className="ct-os-row">
          <span className="ct-os serif-cn">macOS</span>
          <span className="ct-fifteen hero-num">15</span>
          <span className="ct-plus">+</span>
          <h1 className="ct-direct serif-cn">Apple Silicon Direct</h1>
        </div>
        <DirectPack />
        <ul className="ct-outs">
          {OUT.map((name, i) => (
            <li
              key={name}
              className="ct-out"
              style={{ animationDelay: `${2600 + i * 450}ms` }}
            >
              <span className="serif-it">{name}</span>
              <span className="ct-strike" aria-hidden />
            </li>
          ))}
        </ul>
      </div>
    );
  }

  if (step === 1) {
    return (
      <div className="ct-scene scene-pad ct-center" key={step}>
        <div className="ct-oss-head">
          <h1 className="ct-oss serif-it">Open Source</h1>
          <span className="ct-oss-free serif-cn">基础功能免费</span>
        </div>
        <div className="ct-paths">
          {GET_PATHS.map((p, i) => (
            <article
              key={p.name}
              className="ct-path"
              style={{ animationDelay: `${2600 + i * 600}ms` }}
            >
              <h2 className="ct-path-name serif-cn">{p.name}</h2>
              <p className="ct-path-sub">{p.sub}</p>
            </article>
          ))}
        </div>
      </div>
    );
  }

  if (step === 2) {
    return (
      <div className="ct-scene scene-pad ct-center" key={step}>
        <img
          className="ct-logo"
          src="/cta/logo.png"
          width={200}
          height={200}
          alt="Starcat"
        />
        <div className="ct-url-wrap">
          <h1 className="ct-url serif-it">starcat.ink</h1>
          <span className="ct-url-rule" aria-hidden />
        </div>
        <p className="ct-gh mono">
          <span className="ct-gh-tag">open source</span>
          github.com/starcat-app/Starcat
        </p>
        <p className="ct-slogan serif-cn">把吃灰的 Stars 翻出来用</p>
      </div>
    );
  }

  return null;
}
