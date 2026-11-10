# Starcat 诊断分析

报告：F132A38B-E4D7-438D-B977-168ADA4699CC
可用事件：12；筛选事件：12
时间范围：{'first': '2026-11-10T08:17:56.063Z', 'last': '2026-11-10T08:18:07.063Z'}
取消相关：1

## 故障证据

次数为各层观察次数；同一故障可能被多层记录，有请求 ID 时另列实际尝试数。
- license / synthetic：5 次，HTTP=502，错误码=provider_error；后续同一操作成功
  独立请求：5

## 证据缺口

- 采集项 system：notCollected
- 采集项 startup：notCollected
- 采集项 auth：notCollected
- 采集项 keychain：notCollected
- 采集项 subscription：notCollected
- 采集项 network：notCollected
- 采集项 sync：notCollected
- 采集项 readme：notCollected
- 采集项 ai：notCollected
- 采集项 localAI：notCollected
- 采集项 dailyRadar：notCollected
- 采集项 linuxdo：notCollected
- 采集项 recommend：notCollected
- 采集项 weekly：notCollected
- 采集项 rag：notCollected
- 采集项 agent：notCollected
- 采集项 mcp：notCollected
- 采集项 cli：notCollected
- 采集项 extension：notCollected
- 采集项 codeGraph：notCollected
- 采集项 fileAccess：notCollected

## 图谱观测值

- {"cachedCount": 87, "hasNextPage": false, "totalCount": 87}
- {"budget": 78, "canLoadMore": true, "displayedCount": 78, "renderedCount": 78, "totalCount": 87}

## 未闭合操作（结束原因未知）

- {"event": {"category": "runtime", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "eventID": "EF393F48-9737-48C1-AFFF-BC7ED5D719B5", "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "runtime-fixture", "phase": "versionProbe", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:18:07.063Z", "visibility": "context", "fields": {}, "errorChain": []}, "elapsedMs": null, "idleMs": 1173157, "endReason": "unknown"}

## 时间线

```json
{"category": "followGraph", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "eventID": "1C941D79-7447-488D-A12F-8470D324E9B3", "fields": {}, "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "followGraph-fixture", "phase": "started", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:17:56.063Z", "visibility": "context"}
{"category": "followGraph", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "eventID": "0B488F91-38BD-4471-BADE-DF790137E5DB", "fields": {"cachedCount": 87, "hasNextPage": false, "totalCount": 87}, "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "followGraph-fixture", "phase": "pageMerged", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:17:57.063Z", "visibility": "context"}
{"category": "followGraph", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "eventID": "7ABC1FB1-06BA-49C7-8606-23BDEA3AE889", "fields": {"budget": 78, "canLoadMore": true, "displayedCount": 78, "renderedCount": 78, "totalCount": 87}, "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "followGraph-fixture", "phase": "renderConfirmed", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:17:58.063Z", "visibility": "context"}
{"category": "followGraph", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "eventID": "26DEA7DE-016D-4272-AEFC-B1C3D5145348", "fields": {}, "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "followGraph-fixture", "outcome": "partial", "phase": "finished", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:17:59.063Z", "visibility": "context"}
{"category": "license", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "errorCode": "provider_error", "eventID": "EDFAEBF0-AC66-45F3-8D5F-725AAA50CB16", "fields": {}, "level": "warning", "occurrenceCount": 1, "operation": "synthetic", "operationID": "license-fixture", "outcome": "failed", "phase": "http", "requestID": "fixture-1", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "statusCode": 502, "timestamp": "2026-11-10T08:18:00.063Z", "visibility": "context"}
{"category": "license", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "errorCode": "provider_error", "eventID": "0B9E8365-03AE-4769-A284-22969E597EB6", "fields": {}, "level": "warning", "occurrenceCount": 1, "operation": "synthetic", "operationID": "license-fixture", "outcome": "failed", "phase": "http", "requestID": "fixture-2", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "statusCode": 502, "timestamp": "2026-11-10T08:18:01.063Z", "visibility": "context"}
{"category": "license", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "errorCode": "provider_error", "eventID": "0A0AD891-77E1-484A-868C-FE67E553D6E0", "fields": {}, "level": "warning", "occurrenceCount": 1, "operation": "synthetic", "operationID": "license-fixture", "outcome": "failed", "phase": "http", "requestID": "fixture-3", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "statusCode": 502, "timestamp": "2026-11-10T08:18:02.063Z", "visibility": "context"}
{"category": "license", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "errorCode": "provider_error", "eventID": "10859A1A-822A-4167-8864-7218C2D8F699", "fields": {}, "level": "warning", "occurrenceCount": 1, "operation": "synthetic", "operationID": "license-fixture", "outcome": "failed", "phase": "http", "requestID": "fixture-4", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "statusCode": 502, "timestamp": "2026-11-10T08:18:03.063Z", "visibility": "context"}
{"category": "license", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "errorCode": "provider_error", "eventID": "64421093-4241-4A54-8611-EAE90736B094", "fields": {}, "level": "warning", "occurrenceCount": 1, "operation": "synthetic", "operationID": "license-fixture", "outcome": "failed", "phase": "http", "requestID": "fixture-5", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "statusCode": 502, "timestamp": "2026-11-10T08:18:04.063Z", "visibility": "context"}
{"category": "license", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "eventID": "2F0CB502-B6F7-4D49-AAA3-FC658BBC92CC", "fields": {}, "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "license-fixture", "outcome": "succeeded", "phase": "finished", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:18:05.063Z", "visibility": "context"}
{"category": "database", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "eventID": "4B634A37-30F8-4111-B654-B64F8C012744", "fields": {}, "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "database-fixture", "outcome": "cancelled", "phase": "finished", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:18:06.063Z", "visibility": "context"}
{"category": "runtime", "environmentID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "errorChain": [], "eventID": "EF393F48-9737-48C1-AFFF-BC7ED5D719B5", "fields": {}, "level": "info", "occurrenceCount": 1, "operation": "synthetic", "operationID": "runtime-fixture", "phase": "versionProbe", "schemaVersion": 2, "sessionID": "5A419CBF-4EBC-423A-8C58-59265B5D10BF", "sourceFile": "StarcatTests/DiagnosticArchiveTests.swift", "sourceFunction": "append(category:phase:outcome:request:status:fields:)", "sourceLine": 221, "timestamp": "2026-11-10T08:18:07.063Z", "visibility": "context"}
```

时间线截断：False
