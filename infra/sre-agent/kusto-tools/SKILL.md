---
name: SRE Observability - ADX Kusto Tools
description: Kusto (KQL) investigation tools for the AI Observability SRE Demo. Queries ADX cluster aiosreadxdemo4lrdqw, database observability. Use these tools to diagnose incidents, find root causes, and correlate telemetry across APIM, AKS application logs, exceptions, spans, and deployments.
---

## ADX Connection
- Cluster: `https://aiosreadxdemo4lrdqw.australiaeast.kusto.windows.net`
- Database: `observability`
- Tables: `AppLogs`, `AppExceptions`, `AppSpans`, `APIMGatewayLogs`

## When to use these tools

Use these Kusto tools when investigating incidents in the `ai-obs-sre-demo` environment.
Always start with `QueryRecentAppErrors` to get a baseline of what is failing, then drill down.

---

## Tool: QueryRecentAppErrors
**File:** `kusto-tools/QueryRecentAppErrors.kql`  
**Use when:** Alert fires, user reports errors, or you need a baseline of what is currently failing.  
**Parameters:** `timeRange` (default 30m), `service` (default "api-service", use "" for all services)  
**Returns:** Exception counts grouped by ExceptionType, sample messages, correlation_ids

---

## Tool: QueryDependencyErrors
**File:** `kusto-tools/QueryDependencyErrors.kql`  
**Use when:** Suspecting a dependency outage (OpenAI down, Speech failing, Cosmos unreachable, third-party API timeout).  
**Parameters:** `timeRange` (default 30m), `dependency_name` (e.g. "openai", "speech", "cosmos", "thirdparty", use "" for all)  
**Returns:** Dependency error counts, latency p95, error types, affected correlation_ids

---

## Tool: QueryLatencyPercentiles
**File:** `kusto-tools/QueryLatencyPercentiles.kql`  
**Use when:** Users report slowness, or latency alert fires.  
**Parameters:** `timeRange` (default 30m), `service` (default "api-service")  
**Returns:** Latency percentiles p50/p95/p99 per operation, trend over time

---

## Tool: TraceDrilldown
**File:** `kusto-tools/TraceDrilldown.kql`  
**Use when:** You have a `trace_id` or `correlation_id` and need the full end-to-end timeline.  
**Parameters:** `trace_id` (OTel trace_id) OR `correlation_id` (business transaction id)  
**Returns:** All spans, logs, and exceptions in chronological order across all services

---

## Tool: APIMvsBackendCorrelation
**File:** `kusto-tools/APIMvsBackendCorrelation.kql`  
**Use when:** APIM shows 5xx and you need to determine if the fault is in APIM vs the backend.  
**Parameters:** `timeRange` (default 30m), `apiOperation` (use "" for all)  
**Returns:** Joined APIM errors with backend AppExceptions on `x-correlation-id`. No backend match = APIM fault. Backend match = backend fault.

### Guardrail for Scenario 2 (APIM rate-limit / 429)
- Use a short window first: `APIMvsBackendCorrelation(5m, "submit-order")`.
- Prioritize APIM `Status=429` rows for conclusion.
- Treat older backend `500` exceptions from previous scenarios as historical unless they are also present in the same short window.
- If APIM 429 exists with no backend match on `correlation_id`, conclude APIM gateway policy fault.

---

## Tool: DeploymentCorrelation
**File:** `kusto-tools/DeploymentCorrelation.kql`  
**Use when:** Errors started recently and you suspect a bad deployment.  
**Parameters:** `timeRange` (default 2h)  
**Returns:** Error rate trend overlaid with `deployment_version` changes

---

## RCA Decision Tree

1. **Start:** `QueryRecentAppErrors(timeRange="30m")` — what is failing?
2. **If dependency errors:** `QueryDependencyErrors(dependency_name="<name>")` — which dependency?
3. **If you have trace_id/correlation_id:** `TraceDrilldown(trace_id="<id>")` — full evidence chain
4. **If APIM 4xx/429 incident:** start with `APIMvsBackendCorrelation(timeRange="5m", apiOperation="submit-order")` before broad app-error scans
5. **If APIM + backend mismatch:** `APIMvsBackendCorrelation()` — APIM fault vs backend fault
6. **If errors started after a deploy:** `DeploymentCorrelation()` — which version is responsible?
7. **If slow but not erroring:** `QueryLatencyPercentiles()` — latency degradation root cause
