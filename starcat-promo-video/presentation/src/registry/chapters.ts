import type { ChapterDef } from "./types";
import Coldopen from "../chapters/01-coldopen/Coldopen";
import { narrations as coldopenNarrations } from "../chapters/01-coldopen/narrations";
import Product from "../chapters/02-product/Product";
import { narrations as productNarrations } from "../chapters/02-product/narrations";
import Find from "../chapters/03-find/Find";
import { narrations as findNarrations } from "../chapters/03-find/narrations";
import Understand from "../chapters/04-understand/Understand";
import { narrations as understandNarrations } from "../chapters/04-understand/narrations";
import Tags from "../chapters/05-tags/Tags";
import { narrations as tagsNarrations } from "../chapters/05-tags/narrations";
import Organize from "../chapters/06-organize/Organize";
import { narrations as organizeNarrations } from "../chapters/06-organize/narrations";
import Assess from "../chapters/07-assess/Assess";
import { narrations as assessNarrations } from "../chapters/07-assess/narrations";
import LocalNative from "../chapters/08-local-native/LocalNative";
import { narrations as localNativeNarrations } from "../chapters/08-local-native/narrations";
import Cta from "../chapters/09-cta/Cta";
import { narrations as ctaNarrations } from "../chapters/09-cta/narrations";

/**
 * Order = order of presentation.
 * narrations.length is the single source of truth for each chapter's step count.
 */
export const CHAPTERS: ChapterDef[] = [
  { id: "coldopen", title: "收藏夹在吃灰", narrations: coldopenNarrations, Component: Coldopen },
  { id: "product", title: "这就是 Starcat", narrations: productNarrations, Component: Product },
  { id: "find", title: "找回", narrations: findNarrations, Component: Find },
  { id: "understand", title: "理解仓库", narrations: understandNarrations, Component: Understand },
  { id: "tags", title: "建议，不是替你写", narrations: tagsNarrations, Component: Tags },
  { id: "organize", title: "更新与集合", narrations: organizeNarrations, Component: Organize },
  { id: "assess", title: "评估与探索", narrations: assessNarrations, Component: Assess },
  { id: "local-native", title: "数据在你的 Mac 上", narrations: localNativeNarrations, Component: LocalNative },
  { id: "cta", title: "边界与下载", narrations: ctaNarrations, Component: Cta },
];
