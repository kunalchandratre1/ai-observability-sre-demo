// Minimal vanilla JS — no build step needed. Serve `ui/public` from any static host
// (Azure Static Web Apps, Storage $web, or a local `python -m http.server`).
const $ = (id) => document.getElementById(id);
const ls = window.localStorage;

["apim-url","apim-key","user-id","grafana-url"].forEach(k => {
  $(k).value = ls.getItem(k) || $(k).value;
  $(k).addEventListener("change", () => ls.setItem(k, $(k).value));
});

document.querySelectorAll("button[data-copy]").forEach(b => {
  b.addEventListener("click", () => navigator.clipboard.writeText($(b.dataset.copy).textContent.trim()));
});

async function callApim(path, opts = {}) {
  const url = `${$("apim-url").value.replace(/\/$/, "")}${path}`;
  return fetch(url, {
    ...opts,
    headers: {
      "Ocp-Apim-Subscription-Key": $("apim-key").value,
      "Content-Type": "application/json",
      ...(opts.headers || {}),
    },
  });
}

function setIds(j, headers) {
  const cid = j.correlation_id || headers.get("x-correlation-id") || "";
  const rid = j.request_id    || headers.get("x-request-id")    || "";
  const tid = j.trace_id      || headers.get("x-trace-id")      || "";
  const oid = j.order_id      || "";
  $("cid").textContent = cid; $("rid").textContent = rid; $("tid").textContent = tid; $("oid").textContent = oid;
  $("raw").textContent = JSON.stringify(j, null, 2);
  renderDeps(j.dependencies || {});
  buildLinks(tid, cid);
}

function renderDeps(deps) {
  const el = $("deps"); el.innerHTML = "";
  for (const [name, v] of Object.entries(deps)) {
    const div = document.createElement("div");
    div.className = `dep ${v.status}`;
    div.innerHTML = `<strong>${name}</strong><br>status: ${v.status}<br>${v.latency_ms ?? ""}${v.latency_ms?"ms":""}<br><small>${v.error || v.snippet || ""}</small>`;
    el.appendChild(div);
  }
}

function buildLinks(traceId, correlationId) {
  const base = $("grafana-url").value.replace(/\/$/, "");
  const dashes = { d1:"golden-signals", d2:"apim-health", d3:"ai-deps", d4:"cosmos-pe", d5:"thirdparty" };
  for (const [k,v] of Object.entries(dashes)) {
    const a = $(`link-${k}`); a.href = `${base}/d/${v}?var-correlation_id=${encodeURIComponent(correlationId)}&var-trace_id=${encodeURIComponent(traceId)}`;
  }
  $("link-trace").href = `${base}/explore?left=${encodeURIComponent(JSON.stringify({datasource:"ADX",queries:[{kql:`AppSpans | where TraceId == "${traceId}" | order by Timestamp asc`}]}))}`;
}

$("btn-submit").addEventListener("click", async () => {
  try {
    const r = await callApim("/voice/orders", { method:"POST", body: JSON.stringify({ text:$("order-text").value, user_id:$("user-id").value })});
    const j = await r.json();
    setIds(j, r.headers);
  } catch (e) { $("raw").textContent = String(e); }
});

$("btn-burst").addEventListener("click", async () => {
  for (let i=0;i<10;i++) await $("btn-submit").click?.() || $("btn-submit").dispatchEvent(new Event("click"));
});

document.querySelectorAll(".faults button").forEach(b => {
  b.addEventListener("click", async () => {
    const f = b.dataset.fault;
    let body = {};
    if (f === "reset") body = { fault_force_openai_down:false, fault_force_speech_down:false, fault_force_thirdparty_down:false, fault_force_cosmos_dns_break:false, fault_force_exception:false, fault_extra_cpu_burn_ms:0 };
    else if (f === "cpu-burn") body = { fault_extra_cpu_burn_ms: 800 };
    else { const k = `fault_force_${f.replace(/-/g,"_")}`; body[k] = true; }
    const r = await callApim("/voice/admin/faults", { method:"POST", body: JSON.stringify(body) });
    $("fault-state").textContent = JSON.stringify(await r.json(), null, 2);
  });
});

(async () => {
  try {
    if ($("apim-url").value && $("apim-key").value) {
      const r = await callApim("/voice/admin/faults");
      $("fault-state").textContent = JSON.stringify(await r.json(), null, 2);
    }
  } catch {}
})();
