//
//  OpenAIDisableThinkingMiddleware.swift
//  Starcat
//
//  在不 fork MacPaw/OpenAI 的前提下，给已经声明 `reasoning_effort=none` 的 Chat
//  请求补上国内兼容网关常用的关思考字段。
//

import Foundation
import OpenAI

/// Qwen3 / vLLM / SGLang / DashScope 兼容层默认会开 thinking；只靠 prompt 关不掉。
///
/// MacPaw `ChatQuery` 只有官方 `reasoning_effort`。流式请求还绕过诊断 URLSession，
/// 所以用 SDK middleware 改 HTTP body：看见 `reasoning_effort=none` 时再写入
/// `enable_thinking=false`。其它 Chat 请求原样转发。
struct OpenAIDisableThinkingMiddleware: OpenAIMiddleware {
    func intercept(request: URLRequest) -> URLRequest {
        guard request.url?.path.contains("/chat/completions") == true else { return request }
        guard let body = request.httpBody,
              var object = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any],
              object["reasoning_effort"] as? String == "none"
        else {
            return request
        }

        object["enable_thinking"] = false
        if var kwargs = object["chat_template_kwargs"] as? [String: Any] {
            kwargs["enable_thinking"] = false
            object["chat_template_kwargs"] = kwargs
        } else {
            object["chat_template_kwargs"] = ["enable_thinking": false]
        }

        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return request }
        var next = request
        next.httpBody = data
        next.setValue("\(data.count)", forHTTPHeaderField: "Content-Length")
        return next
    }
}
