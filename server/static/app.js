"use strict";

(() => {
  const TOKEN_KEY = "wakemate.admin.token";
  const navItems = [
    ["overview", "总览", "layout-dashboard"], ["patients", "患者与授权", "users"],
    ["plans", "用药计划", "calendar-days"], ["records", "剂次与记录", "clipboard-list"],
    ["devices", "设备", "radio"], ["notifications", "提醒", "bell"],
    ["mcp", "MCP 联调", "plug"], ["audit", "审计日志", "scroll-text"], ["settings", "设置", "settings"]
  ];
  const descriptions = {
    overview: "运营概况与待处理事项", patients: "患者账户与有效授权", plans: "患者的当前用药计划", records: "剂次状态与服药证据", devices: "设备登记与在线状态", notifications: "提醒任务与投递结果", mcp: "患者身份绑定与接入状态", audit: "操作历史与变更追溯", settings: "服务环境与运行配置"
  };
  const patientViews = new Set(["patients", "plans", "records"]);
  const state = { token: sessionStorage.getItem(TOKEN_KEY), patients: [], patientId: "", view: "overview", recordsTab: "doses", table: null, revision: 0, abortController: null, timezone: "Asia/Shanghai" };
  const el = id => document.getElementById(id);
  const escape = value => String(value ?? "").replace(/[&<>"']/g, ch => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[ch]));
  const icon = name => `<i data-lucide="${escape(name)}" aria-hidden="true"></i>`;
  const shown = value => value === null || value === undefined || value === "" ? "--" : escape(value);
  const formatDate = value => {
    if (!value) return "--";
    const date = new Date(value);
    if (Number.isNaN(date.getTime())) return shown(value);
    try { return escape(new Intl.DateTimeFormat("zh-CN", { timeZone: state.timezone, year: "numeric", month: "2-digit", day: "2-digit", hour: "2-digit", minute: "2-digit", hour12: false }).format(date)); }
    catch { return escape(date.toISOString()); }
  };
  const labels = { patient: "患者", caregiver: "家属", admin: "管理员", active: "有效", revoked: "已撤销", expired: "已过期", invited: "等待家属接受", awaiting_patient: "等待患者确认", online: "在线", offline: "离线", pending: "待执行", due: "待确认", unconfirmed: "未确认", confirmed: "已确认", taken: "已确认服药", missed: "未确认", skipped: "已跳过", failed: "失败", sent: "已投递", delivered: "已送达", inbox_ready: "站内信就绪", retrying: "等待重试", queued: "排队中", processing: "执行中", cancelled: "已取消", enabled: "启用", disabled: "停用", completed: "已完成", clear: "无待处理", manual: "手动确认", app: "患者 App", device: "设备事件", mcp: "MCP", pillbox: "药盒", server_saved: "服务端已保存", acknowledged: "设备已确认", user_tap: "患者手动确认", user_voice: "患者语音确认", correction: "患者纠正", confirmation_receipt: "重复请求收据", lid_open: "开盖事件", lid_close: "关盖事件", not_verified: "未核验", ontime: "按时", late: "延迟" };
  function badge(value) {
    if (value === null || value === undefined || value === "") return "--";
    const key = String(value).toLowerCase();
    const tone = ["active", "online", "confirmed", "taken", "sent", "delivered", "enabled", "completed", "clear", "acknowledged", "server_saved", "inbox_ready"].includes(key) ? "success" : ["failed", "revoked"].includes(key) ? "danger" : ["pending", "due", "unconfirmed", "missed", "queued", "processing", "expired", "retrying", "invited", "awaiting_patient"].includes(key) ? "warning" : "";
    return `<span class="badge ${tone}">${escape(labels[key] ?? value)}</span>`;
  }
  function renderIcons() { if (window.lucide) window.lucide.createIcons(); }
  function notify(message) { el("toast").textContent = message; el("toast").hidden = false; clearTimeout(notify.timer); notify.timer = setTimeout(() => { el("toast").hidden = true; }, 4500); }
  class ApiError extends Error { constructor(message, status) { super(message); this.status = status; } }
  async function api(path, options = {}) {
    const timeout = new AbortController();
    const timeoutId = setTimeout(() => timeout.abort(), 20000);
    const sourceSignal = options.signal;
    const abort = () => timeout.abort();
    sourceSignal?.addEventListener("abort", abort, { once: true });
    if (sourceSignal?.aborted) timeout.abort();
    try {
      const response = await fetch(path, { ...options, signal: timeout.signal, headers: { "Content-Type": "application/json", ...(state.token ? { Authorization: `Bearer ${state.token}` } : {}), ...(options.headers ?? {}) } });
      let data = null;
      const text = await response.text();
      if (text) { try { data = JSON.parse(text); } catch { throw new ApiError("服务返回了无法解析的数据，请检查服务状态后重试。", response.status); } }
      if (!response.ok) {
        let message = response.status === 401 ? "登录已过期，请重新登录。" : response.status === 403 ? "当前账户没有此操作权限。" : "请求失败，请稍后重试。";
        if (typeof data?.detail === "string") {
          const bindingErrors = { "Patient not found": "患者账户不存在或已停用，请刷新后重新选择患者。", "Binding not found": "该绑定已不存在，请刷新列表后重试。", "Binding has been revoked": "该绑定已撤销，请新建绑定后连接小智。", "Patient account unavailable": "患者账户已不可用，请检查患者账户状态。" };
          message = path.startsWith("/api/admin/mcp-bindings") ? bindingErrors[data.detail] || data.detail : data.detail;
        }
        else if (Array.isArray(data?.detail)) message = data.detail.map(item => { const field = item.loc?.slice(1).join(".") || "输入"; return item.msg?.includes("Unknown IANA timezone") ? "时区：请填写有效时区，例如 Asia/Shanghai 或 UTC。" : `${field}：${item.msg || "格式不正确"}`; }).join("；");
        if (response.status === 401 && path !== "/api/auth/password") showLogin(message);
        throw new ApiError(message, response.status);
      }
      return data;
    } catch (error) {
      if (error.name === "AbortError") { if (sourceSignal?.aborted) throw error; throw new ApiError("请求超时，请检查网络后重试。", 0); }
      if (error instanceof ApiError) throw error;
      throw new ApiError("无法连接服务，请检查网络和服务状态。", 0);
    } finally { clearTimeout(timeoutId); sourceSignal?.removeEventListener("abort", abort); }
  }
  function requireList(value) { if (!Array.isArray(value)) throw new ApiError("接口数据格式不正确：应返回列表。", 0); return value; }
  function showLogin(message = "") {
    state.token = null; sessionStorage.removeItem(TOKEN_KEY); state.abortController?.abort(); state.patients = []; state.patientId = ""; closeDialog();
    el("workspace").hidden = true; el("login-screen").hidden = false; el("login-error").textContent = message; el("login-error").hidden = !message;
    el("login-form").elements.password.value = ""; closeNavigation();
  }
  function showWorkspace() { el("login-screen").hidden = true; el("workspace").hidden = false; el("login-error").hidden = true; }
  function loading() { el("view").innerHTML = `<div class="table-wrap" aria-busy="true" aria-label="正在加载数据">${Array.from({ length: 6 }, () => `<div class="skeleton-row"><span></span><span></span><span></span><span></span></div>`).join("")}</div>`; }
  function errorView(error) { el("view").innerHTML = `<div class="error-state">${icon("circle-alert")}<div><h2>数据加载失败</h2><p>${escape(error.message)}</p><button class="button small" data-action="reload">${icon("refresh-cw")}重试</button></div></div>`; renderIcons(); }
  function empty(title, message, iconName = "inbox") { return `<div class="empty-state">${icon(iconName)}<h2>${escape(title)}</h2><p>${escape(message)}</p></div>`; }
  function selectedPatient() { return state.patients.find(p => String(p.id) === state.patientId); }
  function patientAccounts() { return state.patients.filter(p => p.role === "patient"); }
  function updatePatientSelect() {
    const select = el("patient-select");
    select.innerHTML = `<option value="">全部账户</option>${patientAccounts().map(p => `<option value="${escape(p.id)}">${escape(p.display_name || p.id)}${p.phone_masked ? ` · ${escape(p.phone_masked)}` : ""}</option>`).join("")}`;
    if (state.view !== "patients") select.options[0].textContent = "选择患者";
    select.value = state.patientId;
    const patient = selectedPatient(); state.timezone = patient?.timezone || "Asia/Shanghai";
    el("patient-timezone").textContent = patient ? `时区：${state.timezone}` : "";
  }
  async function loadPatients(signal) { state.patients = requireList(await api("/api/admin/patients", { signal })); if (state.patientId && !selectedPatient()) state.patientId = ""; updatePatientSelect(); }
  function patientName(id) { const p = state.patients.find(row => String(row.id) === String(id)); return p ? shown(p.display_name) : shown(id); }
  function toolbar(title, actions = "") { return `<div class="view-toolbar"><div class="toolbar-left"><h2 class="section-title">${escape(title)} <span class="count" id="row-count"></span></h2>${actions}</div><div class="toolbar-right"><label class="search-box">${icon("search")}<input id="table-search" type="search" aria-label="搜索当前列表" placeholder="搜索当前列表" autocomplete="off"></label></div></div>`; }
  function setTable(rows, columns, title, actions = "", prefix = "", emptyContent = "") {
    state.table = { rows, columns, page: 1, search: "", pageSize: 30, emptyContent };
    el("view").innerHTML = `${prefix}${toolbar(title, actions)}<div id="table-content"></div>`;
    drawTable();
    el("table-search").addEventListener("input", event => { state.table.search = event.target.value; state.table.page = 1; drawTable(); });
    renderIcons();
  }
  function drawTable() {
    const table = state.table;
    const needle = table.search.trim().toLocaleLowerCase();
    const rows = needle ? table.rows.filter(row => JSON.stringify(row).toLocaleLowerCase().includes(needle)) : table.rows;
    const pages = Math.max(1, Math.ceil(rows.length / table.pageSize)); table.page = Math.min(table.page, pages);
    el("row-count").textContent = `${rows.length} 条`;
    if (!rows.length) { el("table-content").innerHTML = !needle && table.emptyContent ? table.emptyContent : empty(needle ? "没有匹配结果" : "暂无记录", needle ? "调整搜索条件后重试。" : "该列表目前没有数据。", needle ? "search-x" : "inbox"); renderIcons(); return; }
    const visible = rows.slice((table.page - 1) * table.pageSize, table.page * table.pageSize);
    el("table-content").innerHTML = `<div class="table-wrap"><table><thead><tr>${table.columns.map(col => `<th scope="col">${escape(col.title)}</th>`).join("")}</tr></thead><tbody>${visible.map(row => `<tr>${table.columns.map(col => `<td${col.className ? ` class="${escape(col.className)}"` : ""}>${col.render(row)}</td>`).join("")}</tr>`).join("")}</tbody></table></div><div class="table-footer"><span>共 ${rows.length} 条 · 每页 ${table.pageSize} 条</span><div class="pagination"><button class="icon-button" data-action="previous" title="上一页" aria-label="上一页" ${table.page <= 1 ? "disabled" : ""}>${icon("chevron-left")}</button><span class="page-number">${table.page} / ${pages}</span><button class="icon-button" data-action="next" title="下一页" aria-label="下一页" ${table.page >= pages ? "disabled" : ""}>${icon("chevron-right")}</button></div></div>`;
    renderIcons();
  }
  const column = (title, render, className) => ({ title, render, className });
  async function loadView() {
    if (!state.token) return;
    state.abortController?.abort(); state.abortController = new AbortController();
    const signal = state.abortController.signal, revision = ++state.revision;
    state.table = null; el("page-title").textContent = navItems.find(item => item[0] === state.view)[1]; el("breadcrumb").textContent = el("page-title").textContent;
    el("page-context").textContent = descriptions[state.view]; el("patient-filter").hidden = !patientViews.has(state.view);
    el("updated-at").textContent = ""; el("refresh").disabled = true;
    document.querySelectorAll(".nav-button").forEach(button => { const active = button.dataset.view === state.view; button.classList.toggle("active", active); if (active) button.setAttribute("aria-current", "page"); else button.removeAttribute("aria-current"); });
    loading();
    try {
      if (patientViews.has(state.view) || ["mcp", "devices"].includes(state.view)) await loadPatients(signal);
      updatePatientSelect();
      if (revision !== state.revision) return;
      if (["plans", "records"].includes(state.view) && !state.patientId) { el("view").innerHTML = empty("请选择患者", "选择患者后查看当前计划、剂次与服药证据。", "user-round"); renderIcons(); return; }
      await views[state.view](signal);
      if (revision === state.revision) el("updated-at").textContent = `更新于 ${new Intl.DateTimeFormat("zh-CN", { hour: "2-digit", minute: "2-digit", second: "2-digit", hour12: false }).format(new Date())}`;
    } catch (error) { if (error.name !== "AbortError" && revision === state.revision && state.token) errorView(error); }
    finally { if (revision === state.revision) el("refresh").disabled = false; }
  }
  const views = {
    async overview(signal) {
      const [data, status] = await Promise.all([api("/api/admin/overview", { signal }), api("/api/admin/status", { signal })]);
      if (!data || typeof data !== "object") throw new ApiError("总览接口数据格式不正确。", 0);
      const metrics = [["患者", data.patients, ""], ["待执行剂次", data.pending_doses, ""], ["未确认剂次", data.unconfirmed_doses, "attention"], ["已登记设备", data.devices, ""], ["提醒失败", data.notifications_failed, "critical"], ["MCP 绑定", data.mcp_bindings, ""]];
      el("view").innerHTML = `<dl class="metric-band">${metrics.map(([name, value, cls]) => `<div class="${cls}"><dt>${name}</dt><dd>${shown(value)}</dd></div>`).join("")}</dl><section class="section"><div class="section-heading"><h2>待处理事项</h2></div><div class="table-wrap"><table><thead><tr><th>事项</th><th>数量</th><th>状态</th><th>操作</th></tr></thead><tbody><tr><td>未确认的剂次</td><td>${shown(data.unconfirmed_doses)}</td><td>${badge(Number(data.unconfirmed_doses) > 0 ? "unconfirmed" : "clear")}</td><td><button class="row-link" data-view="records">查看剂次${icon("arrow-right")}</button></td></tr><tr><td>投递失败的提醒</td><td>${shown(data.notifications_failed)}</td><td>${badge(Number(data.notifications_failed) > 0 ? "failed" : "clear")}</td><td><button class="row-link" data-view="notifications">查看提醒${icon("arrow-right")}</button></td></tr></tbody></table></div></section><section class="section"><div class="section-heading"><h2>服务状态</h2><button class="row-link" data-view="settings">查看设置${icon("arrow-right")}</button></div>${statusList(status)}</section>`;
      setSidebarStatus(status); renderIcons();
    },
    async patients(signal) {
      const actions = `<button class="button small primary" data-action="create-user">${icon("user-plus")}新建账户</button>${state.patientId ? `<button class="button small" data-action="edit-user" data-id="${escape(state.patientId)}">${icon("pencil")}编辑患者</button>` : ""}`;
      const prefix = `<p class="help-line">患者在 App 完成注册后，会在这里显示；点击刷新获取最新账户。后台也保留新建和编辑入口。</p>`;
      if (state.patientId) {
        const grants = requireList(await api(`/api/admin/patients/${encodeURIComponent(state.patientId)}/grants`, { signal }));
        setTable(grants, [column("家属 / 被授权人", r => patientName(r.caregiver_id)), column("授权范围", r => shown(Array.isArray(r.scopes) ? r.scopes.join("、") : null), "wrap"), column("状态", r => badge(r.status)), column("创建时间", r => formatDate(r.created_at)), column("失效时间", r => formatDate(r.expires_at))], "患者授权", actions, prefix);
      } else {
        setTable(state.patients, [column("账户", r => `${r.role === "patient" ? `<button class="row-link" data-action="select-patient" data-id="${escape(r.id)}">${shown(r.display_name)}${icon("arrow-up-right")}</button>` : shown(r.display_name)}<span class="secondary mono">${shown(r.id)}</span>`), column("登录账号", r => shown(r.username || r.phone_masked)), column("手机号", r => shown(r.phone_masked)), column("角色", r => badge(r.role)), column("时区", r => shown(r.timezone)), column("创建时间", r => formatDate(r.created_at)), column("操作", r => r.role === "patient" ? `<div class="mcp-row-actions"><button class="button small" data-action="edit-user" data-id="${escape(r.id)}">${icon("pencil")}编辑</button><button class="button small" data-action="patient-plans" data-id="${escape(r.id)}">${icon("calendar-days")}计划</button></div>` : "--")], "账户列表", actions, prefix);
      }
    },
    async plans(signal) {
      const rows = requireList(await api(`/api/admin/patients/${encodeURIComponent(state.patientId)}/plans`, { signal }));
      setTable(rows, [column("药物", r => `${shown(r.drug_name)}<span class="secondary mono">${shown(r.id)}</span>`), column("剂量", r => shown(r.dosage)), column("每日时间", r => shown(Array.isArray(r.times) ? r.times.join("、") : null)), column("状态", r => badge(r.active ? "active" : "disabled")), column("版本", r => shown(r.version)), column("硬件同步", r => badge(r.sync_status)), column("备注", r => shown(r.note), "wrap")], "当前计划");
    },
    async records(signal) {
      const type = state.recordsTab;
      const doses = requireList(await api(`/api/admin/patients/${encodeURIComponent(state.patientId)}/${type}`, { signal }));
      const rows = type === "records" ? doses.flatMap(dose => Array.isArray(dose.evidence) ? dose.evidence.map(evidence => ({ ...evidence, dose_id: dose.id, drug_name: dose.drug_name })) : []) : doses;
      const prefix = `<div class="tabs" role="tablist" aria-label="记录视图"><button class="tab ${type === "doses" ? "active" : ""}" role="tab" aria-selected="${type === "doses"}" data-action="records-tab" data-tab="doses">剂次</button><button class="tab ${type === "records" ? "active" : ""}" role="tab" aria-selected="${type === "records"}" data-action="records-tab" data-tab="records">服药证据</button></div>`;
      const columns = type === "doses" ? [column("剂次", r => `${shown(r.drug_name)}<span class="secondary mono">${shown(r.id)}</span>`), column("剂量", r => shown(r.dosage)), column("计划时间", r => formatDate(r.scheduled_time)), column("业务状态", r => badge(r.status)), column("确认时间", r => formatDate(r.actual_time)), column("证据", r => shown(r.evidence_count)), column("同步状态", r => badge(r.sync_status))] : [column("药物", r => `${shown(r.drug_name)}<span class="secondary mono">${shown(r.id)}</span>`), column("关联剂次", r => `<span class="mono">${shown(r.dose_id)}</span>`), column("证据类型", r => badge(r.kind)), column("发生时间", r => formatDate(r.occurred_at)), column("接收时间", r => formatDate(r.received_at)), column("详情", r => shown(r.detail?.reason || r.detail?.note), "wrap")];
      setTable(rows, columns, type === "doses" ? "剂次列表" : "服药证据", "", prefix);
    },
    async devices(signal) {
      const rows = requireList(await api("/api/admin/devices", { signal }));
      setTable(rows, [column("设备序列号", r => `<span class="mono">${shown(r.device_sn)}</span><span class="secondary">${shown(r.id)}</span>`), column("设备类型", r => badge(r.device_type)), column("所属患者", r => patientName(r.patient_id)), column("状态", r => badge(r.active ? r.state?.status : "disabled")), column("最近同步", r => formatDate(r.last_sync_at)), column("药仓", r => shown(r.bead_total)), column("固件", r => shown(r.firmware_ver)), column("传感器", r => badge(r.sensor_capability))], "设备列表", `<button class="button small primary" data-action="create-device">${icon("plus")}登记设备</button>`);
    },
    async notifications(signal) {
      const rows = requireList(await api("/api/admin/notifications", { signal }));
      setTable(rows, [column("提醒", r => `${shown(r.event)}<span class="secondary mono">${shown(r.id)}</span>`), column("患者", r => shown(r.patient_id)), column("渠道", r => r.channel === "inbox" ? "站内信" : shown(r.channel)), column("创建时间", r => formatDate(r.created_at)), column("下次尝试", r => ["queued", "retrying"].includes(r.status) ? formatDate(r.next_attempt_at) : "--"), column("实际送达", r => r.channel === "inbox" ? `--${r.delivered_at ? `<span class="secondary">站内信就绪：${formatDate(r.delivered_at)}</span>` : ""}` : formatDate(r.delivered_at)), column("状态", r => badge(r.status)), column("尝试次数", r => shown(r.attempts)), column("错误", r => shown(r.last_error), "wrap"), column("操作", r => `<button class="button small" data-action="retry-notification" data-id="${escape(r.id)}" ${!["failed", "retrying"].includes(r.status) ? "disabled" : ""}>${icon("rotate-cw")}重试</button>`)], "提醒任务");
    },
    async mcp(signal) {
      const rows = requireList(await api("/api/admin/mcp-bindings", { signal }));
      const hasPatient = patientAccounts().length > 0;
      const prefix = `<section class="mcp-setup" aria-labelledby="mcp-setup-title"><h2 id="mcp-setup-title">把小智连接到醒伴</h2><ol class="mcp-steps"><li><strong>选择患者账户</strong><p>患者从 App 注册后会在后台显示；账户决定小智可查询谁的用药数据。</p></li><li><strong>新建绑定并粘贴接入点</strong><p>在小智控制台的「扩展能力 → MCP 接入点」复制完整 WSS 地址。</p></li><li><strong>确认连接与工具</strong><p>刷新本页查看连接状态，再回小智确认工具可见并尝试查询。</p></li></ol>${!hasPatient ? `<div class="mcp-prerequisite"><div><strong>当前还没有可绑定的患者</strong><p>患者在 App 完成注册后，点击刷新即可选择；也可在此人工新建患者账户。</p></div><button class="button primary" data-action="create-mcp-patient">${icon("user-plus")}新建患者账户</button></div>` : ""}<p class="help-line">「传输已连接」表示已连上小智接入点；首次联调还需在小智中实际调用醒伴工具。接入点含凭证，完整地址只在填写时使用。</p></section>`;
      const emptyContent = `<div class="empty-state">${icon("plug")}<h2>尚未绑定小智</h2><p>${hasPatient ? "选择患者，粘贴从小智控制台复制的 MCP 接入点，即可发起连接。" : "建立患者账户后，选择患者并粘贴小智 MCP 接入点。"}</p><button class="button" data-action="${hasPatient ? "create-binding" : "create-mcp-patient"}">${icon(hasPatient ? "plus" : "user-plus")}${hasPatient ? "新建绑定" : "新建患者账户"}</button></div>`;
      setTable(rows, [column("绑定名称", r => `${shown(r.label)}<span class="secondary mono">${shown(r.id)}</span>`), column("患者", r => patientName(r.patient_id)), column("患者数据授权", r => badge(r.active ? "active" : "revoked")), column("小智连接", r => mcpConnection(r.connection), "wrap"), column("创建时间", r => formatDate(r.created_at)), column("最近工具调用", r => formatDate(r.last_called_at)), column("操作", r => `<div class="mcp-row-actions"><button class="button small" data-action="configure-binding" data-id="${escape(r.id)}" ${!r.active ? "disabled" : ""}>${icon("plug")}${r.connection?.configured ? "更新接入点" : "配置接入点"}</button><button class="button small" data-action="stop-binding" data-id="${escape(r.id)}" ${!r.active || !r.connection?.configured || r.connection?.state === "stopped" ? "disabled" : ""}>${icon("square")}停止连接</button><button class="button small danger" data-action="revoke-binding" data-id="${escape(r.id)}" ${!r.active ? "disabled" : ""}>${icon("unlink")}撤销授权</button></div>`)], "患者绑定", `<button class="button small ${hasPatient ? "primary" : ""}" data-action="create-binding">${icon("plus")}新建绑定</button>`, prefix, emptyContent);
    },
    async audit(signal) {
      const rows = requireList(await api("/api/admin/audit", { signal }));
      setTable(rows, [column("时间", r => formatDate(r.created_at)), column("操作者", r => `<span class="mono">${shown(r.actor_id)}</span>`), column("操作", r => shown(r.action)), column("对象", r => `<span class="mono">${shown(r.object_id)}</span>`), column("请求 ID", r => `<span class="mono">${shown(r.request_id)}</span>`), column("详情", r => `<button class="icon-button" data-action="audit-detail" data-id="${escape(r.id)}" title="查看详情" aria-label="查看审计详情">${icon("file-search")}</button>`)], "审计记录");
    },
    async settings(signal) {
      const status = await api("/api/admin/status", { signal });
      el("view").innerHTML = `<section class="section"><div class="section-heading"><h2>当前运行配置</h2></div>${statusList(status)}</section>`; setSidebarStatus(status); renderIcons();
    }
  };
  function mcpConnection(connection) {
    if (!connection?.configured) return `<span class="badge">未配置接入点</span>`;
    const states = { queued: ["等待连接", "warning"], connecting: ["连接中", "warning"], connected: ["传输已连接", "success"], retrying: ["连接失败，等待重试", "warning"], stopped: ["连接已停止", ""], offline: ["连接离线", ""], error: ["配置错误", "danger"] };
    const [name, tone] = states[connection.state] || ["状态未知", ""];
    return `<span class="badge ${tone}">${name}</span><span class="secondary mono">${shown(connection.endpoint_host)}</span>${connection.connected_at ? `<span class="secondary">连接建立：${formatDate(connection.connected_at)}</span>` : ""}${connection.heartbeat ? `<span class="secondary">最近检查：${formatDate(connection.heartbeat)}</span>` : ""}${connection.last_error ? `<span class="secondary mcp-error">错误：${shown(connection.last_error)}</span>` : ""}`;
  }
  function statusList(status) {
    const worker = status?.worker;
    const workerValue = worker?.healthy ? "运行正常" : "心跳未就绪";
    const rows = [["环境", status?.environment], ["认证方式", status?.auth_mode === "password_registration_and_operator_otp" ? "账号密码注册 / 登录" : status?.auth_mode === "password_and_operator_otp" ? "密码 / 运维验证码" : status?.auth_mode], ["提醒渠道", status?.notification_channel === "inbox" ? "站内信" : status?.notification_channel], ["外部推送", status?.external_push === "configured" ? "已配置" : "未配置"], ["提醒 Worker", workerValue], ["Worker 最近心跳", worker?.heartbeat ? new Date(worker.heartbeat).toLocaleString("zh-CN") : "--"], ["MCP 绑定", status?.mcp_bindings]];
    return `<dl class="plain-status">${rows.map(([name, value]) => `<div><dt>${escape(name)}</dt><dd>${shown(value)}</dd></div>`).join("")}</dl>`;
  }
  function setSidebarStatus(status) { el("sidebar-status").textContent = status?.environment ? `服务已连接 · ${status.environment}` : "服务已连接"; el("sidebar-status").parentElement.classList.add("is-ready"); }
  function navigate(view) {
    if (!navItems.some(item => item[0] === view)) return;
    state.view = view; history.replaceState(null, "", `#${view}`); closeNavigation(); loadView();
  }
  function closeNavigation() { el("workspace").classList.remove("nav-open"); el("sidebar-scrim").hidden = true; el("menu-toggle").setAttribute("aria-expanded", "false"); }
  function closeDialog() { const dialog = el("action-dialog"); if (dialog.open) dialog.close(); el("dialog-body").replaceChildren(); }
  function openDialog(title, body) { el("dialog-title").textContent = title; el("dialog-body").innerHTML = body; renderIcons(); if (!el("action-dialog").open) el("action-dialog").showModal(); }
  function actions(submit = "创建", danger = false) { return `<div class="form-error" id="dialog-error" role="alert" tabindex="-1" hidden></div><div class="dialog-actions"><button class="button" type="button" data-dialog-close>取消</button><button class="button ${danger ? "danger" : "primary"}" type="submit">${icon(danger ? "unlink" : "check")}<span>${escape(submit)}</span></button></div>`; }
  function bindSubmit(callback) {
    const form = el("dialog-form");
    form.addEventListener("submit", async event => {
      event.preventDefault();
      if (form.dataset.pending === "true") return;
      const button = form.querySelector("button[type=submit]"), original = button.innerHTML;
      form.dataset.pending = "true"; form.setAttribute("aria-busy", "true"); button.disabled = true; button.textContent = "提交中…"; el("dialog-error").hidden = true;
      try { await callback(new FormData(form)); }
      catch (error) { if (form.isConnected && el("dialog-error")) { el("dialog-error").textContent = error.message; el("dialog-error").hidden = false; el("dialog-error").focus(); } }
      finally { form.dataset.pending = "false"; form.removeAttribute("aria-busy"); if (button.isConnected) { button.disabled = false; button.innerHTML = original; renderIcons(); } }
    });
  }
  function showSecrets(title, data, fields) {
    const body = `<p class="dialog-copy">以下凭证仅展示这一次。关闭窗口后无法再次查看，请妥善保管。</p>${fields.map(([key, name]) => `<div class="secret-field"><label>${escape(name)}</label><div class="secret-value"><code data-secret="${escape(key)}">${shown(data[key])}</code><button class="icon-button" type="button" data-copy-secret="${escape(key)}" title="复制${escape(name)}" aria-label="复制${escape(name)}">${icon("copy")}</button></div></div>`).join("")}<div class="dialog-actions"><button class="button primary" type="button" data-dialog-close>${icon("check")}已保存，关闭</button></div>`;
    openDialog(title, body);
  }
  function createUser(forMcp = false) {
    openDialog(forMcp ? "新建患者账户" : "新建账户", `<form id="dialog-form">${forMcp ? `<p class="dialog-copy">请填写真实患者信息。创建后即可在 MCP 联调中选择该患者，并绑定小智接入点。</p>` : ""}<div class="form-grid"><label class="full">姓名<input name="display_name" required maxlength="100" autocomplete="off"></label><label>手机号<input name="phone" required inputmode="tel" autocomplete="off" pattern="1[3-9][0-9]{9}" maxlength="11"></label><label>角色<select name="role"><option value="patient">患者</option>${forMcp ? "" : `<option value="caregiver">家属</option>`}</select></label><label class="full">初始密码<input name="password" type="password" required minlength="12" maxlength="128" autocomplete="new-password" placeholder="至少 12 位"></label><label class="full">时区<input name="timezone" required value="Asia/Shanghai" autocomplete="off"></label></div>${actions(forMcp ? "创建患者账户" : "创建账户")}</form>`);
    bindSubmit(async data => { await api("/api/admin/users", { method: "POST", body: JSON.stringify(Object.fromEntries(data)) }); closeDialog(); notify(forMcp ? "患者账户已创建，可继续新建 MCP 绑定" : "账户已创建"); await loadView(); });
  }
  function editUser(id) {
    const row = state.patients.find(item => String(item.id) === String(id));
    if (!row || row.role !== "patient") return;
    openDialog("编辑患者账户", `<form id="dialog-form"><p class="dialog-copy">修改患者的显示信息。登录账号、手机号与角色只读。</p><div class="form-grid"><label class="full">姓名<input name="display_name" required maxlength="100" autocomplete="off" value="${escape(row.display_name || "")}"></label><label class="full">登录账号<input name="username" value="${escape(row.username || row.phone_masked || "--")}" disabled aria-describedby="edit-user-readonly"></label><label>手机号<input name="phone" value="${escape(row.phone_masked || "--")}" disabled aria-describedby="edit-user-readonly"></label><label>角色<input name="role" value="患者" disabled aria-describedby="edit-user-readonly"></label><label class="full">时区<input name="timezone" required maxlength="60" autocomplete="off" value="${escape(row.timezone || "Asia/Shanghai")}"></label></div><p id="edit-user-readonly" class="field-hint">保存只会更新姓名和时区；账号密码注册无需填写手机号。</p>${actions("保存修改")}</form>`);
    bindSubmit(async data => { await api(`/api/admin/users/${encodeURIComponent(id)}`, { method: "PUT", body: JSON.stringify({ display_name: String(data.get("display_name") || "").trim(), timezone: String(data.get("timezone") || "").trim() }) }); closeDialog(); notify("患者账户已更新"); await loadView(); });
  }
  function createDevice() {
    openDialog("登记设备", `<form id="dialog-form"><label>设备序列号<input name="device_sn" required autocomplete="off" maxlength="64"></label><div class="form-grid" style="margin-top:18px"><label>设备类型<select name="device_type"><option value="pillbox">药盒</option></select></label><label>药仓数量<input name="bead_total" type="number" min="1" max="20" value="2" required></label></div>${actions("登记设备")}</form>`);
    bindSubmit(async data => { const payload = Object.fromEntries(data); payload.bead_total = Number(payload.bead_total); const result = await api("/api/admin/devices", { method: "POST", body: JSON.stringify(payload) }); showSecrets("设备已登记", result, [["id", "设备 ID"], ["claim_code", "绑定码"], ["device_token", "设备凭证"]]); await loadView(); });
  }
  function createBinding() {
    if (!patientAccounts().length) {
      openDialog("暂无可绑定患者", `<p class="dialog-copy">MCP 绑定需要指定患者，决定小智可查询谁的用药数据。患者在 App 完成注册后，刷新本页即可选择；也可人工新建患者账户。</p><div class="dialog-actions"><button class="button" type="button" data-dialog-close>稍后</button><button class="button primary" type="button" data-action="create-mcp-patient">${icon("user-plus")}新建患者账户</button></div>`);
      return;
    }
    openDialog("新建 MCP 绑定", `<form id="dialog-form"><label>患者<select name="patient_id" required aria-describedby="binding-patient-help"><option value="">选择患者</option>${patientAccounts().map(p => `<option value="${escape(p.id)}">${escape(p.display_name)} · ${escape(p.username || p.phone_masked || p.id)}</option>`).join("")}</select></label><p id="binding-patient-help" class="field-hint">此患者账户决定小智可查询谁的数据。</p><label>绑定名称<input name="label" required maxlength="100" autocomplete="off" placeholder="例如：床头小智"></label>${mcpEndpointField()}${actions("保存并连接")}</form>`);
    bindSubmit(async data => { const payload = Object.fromEntries(data); payload.endpoint = validatedEndpoint(data); await api("/api/admin/mcp-bindings", { method: "POST", body: JSON.stringify(payload) }); closeDialog(); notify("绑定已保存，正在发起小智连接；请刷新查看状态"); await loadView(); });
  }
  function mcpEndpointField() {
    return `<label class="mcp-endpoint-label">小智 MCP 接入点<input name="endpoint" type="password" required maxlength="4096" autocomplete="off" spellcheck="false" autocapitalize="none" inputmode="url" aria-describedby="endpoint-help" placeholder="wss://api.xiaozhi.me/mcp/?token=…"></label><p id="endpoint-help" class="field-hint">在小智控制台打开智能体配置，进入「扩展能力 → MCP 接入点」，点击复制后粘贴完整 WSS 地址。地址含凭证，保存后不再回显。</p>`;
  }
  function validatedEndpoint(data) {
    const endpoint = String(data.get("endpoint") || "").trim();
    let url;
    try { url = new URL(endpoint); } catch { throw new ApiError("接入点格式不正确，请重新复制小智控制台中的完整 WSS 地址。", 422); }
    if (url.protocol !== "wss:") throw new ApiError("接入点必须以 wss:// 开头，请复制小智控制台提供的 MCP 接入点。", 422);
    return endpoint;
  }
  function configureBinding(id) {
    const row = state.table?.rows.find(item => String(item.id) === id);
    if (!row?.active) return;
    openDialog("配置小智接入点", `<form id="dialog-form"><p class="dialog-copy">绑定：${escape(row.label)}<br>患者：${patientName(row.patient_id)}。粘贴完整接入点后，服务将发起连接。${row.connection?.configured ? `<br>当前接入域名：${shown(row.connection.endpoint_host)}。请重新粘贴地址，保存后重新连接。` : ""}</p>${mcpEndpointField()}${actions("保存并连接")}</form>`);
    bindSubmit(async data => { await api(`/api/admin/mcp-bindings/${encodeURIComponent(id)}/connection`, { method: "PUT", body: JSON.stringify({ endpoint: validatedEndpoint(data) }) }); closeDialog(); notify("接入点已保存，正在重新连接；请刷新查看状态"); await loadView(); });
  }
  function stopBinding(id) {
    const row = state.table?.rows.find(item => String(item.id) === id);
    if (!row?.active || !row.connection?.configured) return;
    openDialog("停止小智连接", `<form id="dialog-form"><p class="dialog-copy">停止“${escape(row.label)}”会断开小智连接。稍后可通过「配置接入点」重新连接。</p>${actions("确认停止", true)}</form>`);
    bindSubmit(async () => { await api(`/api/admin/mcp-bindings/${encodeURIComponent(id)}/connection`, { method: "DELETE" }); closeDialog(); notify("小智连接已停止"); await loadView(); });
  }
  function revokeBinding(id) {
    const row = state.table?.rows.find(item => String(item.id) === id);
    openDialog("撤销 MCP 绑定", `<form id="dialog-form"><p class="dialog-copy">撤销“${escape(row?.label || id)}”后，该凭证将无法继续访问患者数据。</p>${actions("确认撤销", true)}</form>`);
    bindSubmit(async () => { await api(`/api/admin/mcp-bindings/${encodeURIComponent(id)}/revoke`, { method: "POST" }); closeDialog(); notify("绑定已撤销"); await loadView(); });
  }
  async function retryNotification(id, button) { button.disabled = true; try { await api(`/api/admin/notifications/${encodeURIComponent(id)}/retry`, { method: "POST" }); notify("已提交重试"); await loadView(); } catch (error) { notify(error.message); if (button.isConnected) button.disabled = false; } }
  function auditDetail(id) { const row = state.table?.rows.find(item => String(item.id) === id); if (!row) return; openDialog("审计详情", `<pre class="details-box">${escape(JSON.stringify(row, null, 2))}</pre><div class="dialog-actions"><button class="button" type="button" data-dialog-close>关闭</button></div>`); }
  el("navigation").innerHTML = navItems.map(([key, name, iconName]) => `<button class="nav-button" type="button" data-view="${key}">${icon(iconName)}<span>${name}</span></button>`).join("");
  document.addEventListener("click", event => {
    const button = event.target.closest("button"); if (!button || button.disabled) return;
    if (button.dataset.view) { navigate(button.dataset.view); return; }
    if (button.hasAttribute("data-dialog-close")) { closeDialog(); return; }
    const action = button.dataset.action, id = button.dataset.id;
    if (action === "reload") loadView();
    if (action === "previous" || action === "next") { state.table.page += action === "next" ? 1 : -1; drawTable(); }
    if (action === "select-patient" || action === "patient-plans") { state.patientId = id; navigate(action === "patient-plans" ? "plans" : "patients"); }
    if (action === "records-tab") { state.recordsTab = button.dataset.tab; loadView(); }
    if (action === "create-user") createUser();
    if (action === "edit-user") editUser(id);
    if (action === "create-mcp-patient") createUser(true);
    if (action === "create-device") createDevice();
    if (action === "create-binding") createBinding();
    if (action === "configure-binding") configureBinding(id);
    if (action === "stop-binding") stopBinding(id);
    if (action === "revoke-binding") revokeBinding(id);
    if (action === "retry-notification") retryNotification(id, button);
    if (action === "audit-detail") auditDetail(id);
    if (button.dataset.copySecret) {
      const code = Array.from(el("dialog-body").querySelectorAll("[data-secret]")).find(node => node.dataset.secret === button.dataset.copySecret);
      if (code) { if (!navigator.clipboard) notify("当前浏览器不能复制，请手动选择凭证。"); else navigator.clipboard.writeText(code.textContent).then(() => notify("已复制"), () => notify("复制失败，请手动选择凭证。")); }
    }
  });
  el("patient-select").addEventListener("change", event => { state.patientId = event.target.value; loadView(); });
  el("refresh").addEventListener("click", loadView);
  el("logout").addEventListener("click", () => showLogin());
  el("dialog-close").addEventListener("click", closeDialog);
  el("action-dialog").addEventListener("close", () => el("dialog-body").replaceChildren());
  el("menu-toggle").addEventListener("click", () => { const open = !el("workspace").classList.contains("nav-open"); el("workspace").classList.toggle("nav-open", open); el("sidebar-scrim").hidden = !open; el("menu-toggle").setAttribute("aria-expanded", String(open)); });
  el("sidebar-scrim").addEventListener("click", closeNavigation);
  document.addEventListener("keydown", event => { if (event.key === "Escape") closeNavigation(); });
  el("login-form").addEventListener("submit", async event => {
    event.preventDefault(); const form = event.target, button = form.querySelector("button"); button.disabled = true; el("login-error").hidden = true;
    try {
      const data = await api("/api/auth/password", { method: "POST", body: JSON.stringify({ username: form.elements.username.value.trim(), password: form.elements.password.value }) });
      const token = data?.access_token || data?.token;
      if (!token) throw new ApiError("登录响应未返回凭证，请检查服务配置。", 0);
      if (data.role !== "admin") throw new ApiError("请使用管理员账户登录管理工作台。", 403);
      state.token = token; sessionStorage.setItem(TOKEN_KEY, token); el("signed-in-user").textContent = data.user?.display_name || data.display_name || form.elements.username.value;
      form.elements.password.value = ""; showWorkspace(); navigate(state.view);
    } catch (error) { el("login-error").textContent = error.message; el("login-error").hidden = false; }
    finally { button.disabled = false; }
  });
  window.addEventListener("hashchange", () => { const view = location.hash.slice(1); if (view !== state.view && navItems.some(item => item[0] === view)) navigate(view); });
  const hashView = location.hash.slice(1); if (navItems.some(item => item[0] === hashView)) state.view = hashView;
  renderIcons(); if (state.token) { showWorkspace(); loadView(); }
})();
