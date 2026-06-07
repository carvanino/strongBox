import { useState, useEffect, useRef, useCallback } from "react";

// ─── Theme ────────────────────────────────────────────────────────────────────
const T = {
  bg:      "#080b0f",
  bgCard:  "#0e1318",
  bgInput: "#131920",
  border:  "#1e2d3d",
  borderBright: "#2a4159",
  text:    "#c9d8e8",
  textDim: "#4a6275",
  textBright: "#e8f4ff",
  amber:   "#f0a500",
  amberDim:"#7a5200",
  green:   "#00c97a",
  greenDim:"#004d30",
  red:     "#ff4d6a",
  redDim:  "#4d0017",
  blue:    "#4da6ff",
  blueDim: "#0d2d4d",
  purple:  "#a855f7",
};

const globalStyles = `
  @import url('https://fonts.googleapis.com/css2?family=JetBrains+Mono:wght@300;400;500;700&family=IBM+Plex+Sans:wght@300;400;500;600&display=swap');
  * { box-sizing: border-box; margin: 0; padding: 0; }
  body {
    background: ${T.bg};
    color: ${T.text};
    font-family: 'IBM Plex Sans', sans-serif;
    font-size: 13px;
    line-height: 1.5;
    overflow: hidden;
  }
  ::-webkit-scrollbar { width: 4px; height: 4px; }
  ::-webkit-scrollbar-track { background: ${T.bg}; }
  ::-webkit-scrollbar-thumb { background: ${T.border}; border-radius: 2px; }
  .fade-in { animation: fadeIn 0.2s ease; }
  @keyframes fadeIn { from { opacity: 0; transform: translateY(4px); } to { opacity: 1; transform: none; } }
  @keyframes pulse { 0%,100% { opacity: 1; } 50% { opacity: 0.4; } }
`;

// ─── Components ───────────────────────────────────────────────────────────────
function Badge({ children, color = T.amber }) {
  return (
    <span style={{
      display: "inline-block", padding: "1px 7px", borderRadius: 3,
      background: color + "22", border: `1px solid ${color}44`,
      color, fontSize: 10, fontFamily: "JetBrains Mono", fontWeight: 500,
      letterSpacing: "0.05em", textTransform: "uppercase",
    }}>
      {children}
    </span>
  );
}

function StatusDot({ status }) {
  const colors = { up: T.green, down: T.red, sealed: T.amber, unknown: T.textDim };
  const c = colors[status] || T.textDim;
  return (
    <span style={{
      display: "inline-block", width: 8, height: 8, borderRadius: "50%",
      background: c, boxShadow: `0 0 6px ${c}`,
      animation: status === "up" ? "pulse 2s infinite" : "none",
    }} />
  );
}

function Btn({ children, onClick, variant = "primary", small, disabled, loading }) {
  const colors = {
    primary: { bg: T.amber + "18", border: T.amber + "44", text: T.amber, hover: T.amber + "28" },
    danger:  { bg: T.red   + "18", border: T.red   + "44", text: T.red,   hover: T.red   + "28" },
    ghost:   { bg: "transparent",  border: T.border,        text: T.textDim, hover: T.bgCard },
    success: { bg: T.green + "18", border: T.green + "44", text: T.green, hover: T.green + "28" },
  };
  const c = colors[variant];
  return (
    <button
      onClick={disabled || loading ? undefined : onClick}
      style={{
        display: "inline-flex", alignItems: "center", gap: 6,
        padding: small ? "4px 12px" : "7px 16px",
        background: c.bg, border: `1px solid ${c.border}`, borderRadius: 4,
        color: disabled ? T.textDim : c.text,
        fontFamily: "JetBrains Mono", fontSize: small ? 10 : 11, fontWeight: 500,
        cursor: disabled ? "not-allowed" : "pointer",
        opacity: disabled ? 0.5 : 1,
        transition: "all 0.15s",
        letterSpacing: "0.03em",
      }}
    >
      {loading ? <span style={{ animation: "pulse 0.8s infinite" }}>⟳</span> : null}
      {children}
    </button>
  );
}

function Input({ label, value, onChange, placeholder, type = "text", mono: isMono }) {
  return (
    <div style={{ display: "flex", flexDirection: "column", gap: 4 }}>
      {label && <label style={{ color: T.textDim, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase" }}>{label}</label>}
      <input
        type={type}
        value={value}
        onChange={e => onChange(e.target.value)}
        placeholder={placeholder}
        style={{
          background: T.bgInput, border: `1px solid ${T.border}`, borderRadius: 4,
          padding: "7px 12px", color: T.textBright,
          fontFamily: isMono ? "JetBrains Mono" : "IBM Plex Sans",
          fontSize: isMono ? 11 : 13, outline: "none", width: "100%",
        }}
      />
    </div>
  );
}

function Card({ children, style }) {
  return (
    <div style={{
      background: T.bgCard, border: `1px solid ${T.border}`, borderRadius: 6,
      padding: 16, ...style
    }}>
      {children}
    </div>
  );
}

function SectionHeader({ title, subtitle }) {
  return (
    <div style={{ marginBottom: 20 }}>
      <div style={{ display: "flex", alignItems: "center", gap: 10, marginBottom: 4 }}>
        <div style={{ width: 3, height: 20, background: T.amber, borderRadius: 2 }} />
        <h2 style={{ color: T.textBright, fontSize: 15, fontWeight: 600 }}>{title}</h2>
      </div>
      {subtitle && <p style={{ color: T.textDim, fontSize: 12, paddingLeft: 13 }}>{subtitle}</p>}
    </div>
  );
}

function Terminal({ logs }) {
  const ref = useRef();
  useEffect(() => { if (ref.current) ref.current.scrollTop = ref.current.scrollHeight; }, [logs]);
  return (
    <div style={{
      background: "#060911", border: `1px solid ${T.border}`, borderRadius: 6,
      height: "100%", display: "flex", flexDirection: "column", overflow: "hidden",
    }}>
      <div style={{
        padding: "8px 14px", borderBottom: `1px solid ${T.border}`,
        display: "flex", alignItems: "center", gap: 8,
      }}>
        <div style={{ display: "flex", gap: 5 }}>
          {[T.red, T.amber, T.green].map((c, i) => (
            <div key={i} style={{ width: 10, height: 10, borderRadius: "50%", background: c + "88" }} />
          ))}
        </div>
        <span style={{ color: T.textDim, fontSize: 10, fontFamily: "JetBrains Mono", letterSpacing: "0.05em" }}>
          API CONSOLE
        </span>
      </div>
      <div ref={ref} style={{ flex: 1, overflowY: "auto", padding: 14, fontFamily: "JetBrains Mono", fontSize: 11 }}>
        {logs.length === 0 && <div style={{ color: T.textDim }}>— awaiting operations —</div>}
        {logs.map((log, i) => (
          <div key={i} style={{ marginBottom: 12 }}>
            <div style={{ color: T.textDim, fontSize: 10, marginBottom: 2 }}>{log.ts}</div>
            <div style={{ color: log.method === "GET" ? T.blue : log.method === "PUT" ? T.purple : T.amber }}>
              {log.method} {log.path}
            </div>
            {log.body && <div style={{ color: T.textDim, paddingLeft: 12, marginTop: 2 }}>{log.body}</div>}
            <div style={{
              marginTop: 4, paddingLeft: 12,
              color: log.ok ? T.green : T.red,
              borderLeft: `2px solid ${log.ok ? T.green + "44" : T.red + "44"}`,
              paddingTop: 2,
            }}>
              {log.ok ? "✓" : "✗"} {log.status} {log.response
                ? (typeof log.response === "string"
                    ? log.response.slice(0, 200)
                    : JSON.stringify(log.response).slice(0, 200))
                : ""}
            </div>
          </div>
        ))}
      </div>
    </div>
  );
}

// ─── Main App ─────────────────────────────────────────────────────────────────
export default function App() {
  const [baseURL, setBaseURL] = useState("");
  const [token, setToken] = useState("");
  const [logs, setLogs] = useState([]);
  const [activeSection, setActiveSection] = useState("health");
  const [nodeHealth, setNodeHealth] = useState(null);
  const [loading, setLoad_] = useState({});

  // Scenario state
  const [initResult, setInitResult] = useState(null);
  const [shares, setShares] = useState(["", "", ""]);
  const [unsealProgress, setUnsealProgress] = useState(null);
  const [secretPath, setSecretPath] = useState("app/db");
  const [secretData, setSecretData] = useState('{"password":"postgres123"}');
  const [secretResult, setSecretResult] = useState(null);
  const [readVersion, setReadVersion] = useState("");
  const [policyName, setPolicyName] = useState("read-only");
  const [policyRules, setPolicyRules] = useState('[{"path":"secret/app/*","capabilities":["read"]}]');
  const [newUsername, setNewUsername] = useState("demouser");
  const [newPassword, setNewPassword] = useState("demopass123");
  const [loginUser, setLoginUser] = useState("demouser");
  const [loginPass, setLoginPass] = useState("demopass123");
  const [scopedToken, setScopedToken] = useState("");
  const [dynamicRole, setDynamicRole] = useState("readonly");
  const [dynamicCred, setDynamicCred] = useState(null);
  const [leaseState, setLeaseState] = useState(null);
  const [leasePolling, setLeasePolling] = useState(false);
  const [auditLog, setAuditLog] = useState([]);
  const [verifyResult, setVerifyResult] = useState(null);

  const setLoad = (key, val) => setLoad_(prev => ({ ...prev, [key]: val }));

  const addLog = useCallback((method, path, body, status, response) => {
    const ok = status >= 200 && status < 300;
    setLogs(prev => [...prev.slice(-50), {
      ts: new Date().toISOString().slice(11, 23),
      method, path,
      body: body ? JSON.stringify(body).slice(0, 80) : null,
      status, response, ok,
    }]);
    return ok;
  }, []);

  const api = useCallback(async (method, path, body, useToken = true) => {
    const url = `${baseURL}${path}`;
    const headers = { "Content-Type": "application/json" };
    if (useToken && token) headers["Authorization"] = `Bearer ${token}`;
    try {
      const resp = await fetch(url, {
        method, headers,
        body: body ? JSON.stringify(body) : undefined,
      });
      const text = await resp.text();
      let data;
      try { data = JSON.parse(text); } catch { data = text; }
      addLog(method, path, body, resp.status, data);
      return { ok: resp.ok, status: resp.status, data };
    } catch (e) {
      addLog(method, path, body, 0, `Network error: ${e.message}`);
      return { ok: false, status: 0, data: null };
    }
  }, [baseURL, token, addLog]);

  // Health polling
  useEffect(() => {
    const poll = async () => {
      try {
        const res = await fetch(`${baseURL}/v1/sys/health`);
        const d = await res.json();
        setNodeHealth(d);
      } catch { setNodeHealth(null); }
    };
    poll();
    const t = setInterval(poll, 5000);
    return () => clearInterval(t);
  }, [baseURL]);

  // ── Handlers ────────────────────────────────────────────────────────────────
  const doInit = async () => {
    setLoad("init", true);
    const r = await api("POST", "/v1/sys/init", { secret_shares: 3, secret_threshold: 2 });
    if (r.ok && r.data?.shares) {
      setInitResult(r.data);
      setToken(r.data.root_token);
      setShares(r.data.shares);
    }
    setLoad("init", false);
  };

  const doUnseal = async (i) => {
    setLoad(`unseal${i}`, true);
    const r = await api("POST", "/v1/sys/unseal", { share: shares[i] }, false);
    if (r.ok) setUnsealProgress(r.data);
    setLoad(`unseal${i}`, false);
  };

  const doWriteSecret = async () => {
    setLoad("writeSecret", true);
    let parsed;
    try { parsed = JSON.parse(secretData); } catch { parsed = { value: secretData }; }
    const r = await api("PUT", `/v1/secrets/${secretPath}`, parsed);
    if (r.ok) setSecretResult(r.data);
    setLoad("writeSecret", false);
  };

  const doReadSecret = async () => {
    setLoad("readSecret", true);
    const path = readVersion
      ? `/v1/secrets/${secretPath}?version=${readVersion}`
      : `/v1/secrets/${secretPath}`;
    const r = await api("GET", path);
    if (r.ok) setSecretResult(r.data);
    setLoad("readSecret", false);
  };

  const doCreatePolicy = async () => {
    setLoad("policy", true);
    let rules;
    try { rules = JSON.parse(policyRules); } catch { rules = []; }
    await api("PUT", `/v1/policies/${policyName}`, { rules });
    setLoad("policy", false);
  };

  const doCreateUser = async () => {
    setLoad("user", true);
    await api("PUT", `/v1/users/${newUsername}`, {
      password: newPassword, policies: [policyName],
    });
    setLoad("user", false);
  };

  const doLogin = async () => {
    setLoad("login", true);
    const r = await api("POST", "/v1/auth/login",
      { username: loginUser, password: loginPass }, false);
    if (r.ok && r.data?.token) setScopedToken(r.data.token);
    setLoad("login", false);
  };

  const doRevokeScoped = async () => {
    setLoad("revoke", true);
    await api("POST", "/v1/auth/revoke", { token: scopedToken });
    setLoad("revoke", false);
  };

  const testWithScopedToken = async (method, path, body) => {
    const headers = { "Authorization": `Bearer ${scopedToken}`, "Content-Type": "application/json" };
    try {
      const r = await fetch(`${baseURL}${path}`, {
        method, headers, body: body ? JSON.stringify(body) : undefined,
      });
      const d = await r.json().catch(() => ({}));
      addLog(method, path, body, r.status, d);
    } catch (e) { addLog(method, path, body, 0, e.message); }
  };

  const doMintDynamic = async () => {
    setLoad("dynamic", true);
    const r = await api("GET", `/v1/dynamic-postgres/${dynamicRole}`);
    if (r.ok && r.data?.username) setDynamicCred(r.data);
    setLoad("dynamic", false);
  };

  const doRevokeDynamic = async () => {
    if (!dynamicCred?.lease_id) return;
    setLoad("revokeDynamic", true);
    await api("POST", `/v1/leases/${dynamicCred.lease_id}/revoke`);
    setLoad("revokeDynamic", false);
  };

  const pollLeaseState = async (leaseId) => {
    if (!leaseId) return;
    setLeasePolling(true);
    const r = await api("GET", `/v1/leases/${leaseId}`);
    if (r.ok && r.data) setLeaseState(r.data);
    setLeasePolling(false);
  };

  const doAuditVerify = async (tamper) => {
    setLoad(tamper ? "verifyTamper" : "verifyClean", true);
    const r = await api("GET", `/v1/sys/audit/verify?tamper=${tamper}`);
    if (r.data) setVerifyResult(r.data);
    setLoad(tamper ? "verifyTamper" : "verifyClean", false);
  };

  // ── Sections ─────────────────────────────────────────────────────────────────
  const sealed = nodeHealth?.sealed !== false;

  const renderHealth = () => (
    <div className="fade-in">
      <SectionHeader title="Cluster Status" subtitle="Live health of the 3-node StrongBox cluster" />
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr 1fr", gap: 12, marginBottom: 16 }}>
        {["node1", "node2", "node3"].map((n, i) => (
          <Card key={n}>
            <div style={{ display: "flex", justifyContent: "space-between", alignItems: "center", marginBottom: 12 }}>
              <span style={{ fontFamily: "JetBrains Mono", color: T.textBright, fontWeight: 600 }}>{n}</span>
              <StatusDot status={i === 0 && nodeHealth ? (nodeHealth.sealed ? "sealed" : "up") : "unknown"} />
            </div>
            <div style={{ display: "flex", flexDirection: "column", gap: 6 }}>
              <div style={{ display: "flex", justifyContent: "space-between" }}>
                <span style={{ color: T.textDim }}>Status</span>
                {i === 0 && nodeHealth
                  ? <Badge color={nodeHealth.sealed ? T.amber : T.green}>{nodeHealth.sealed ? "SEALED" : "UNSEALED"}</Badge>
                  : <Badge color={T.textDim}>UNKNOWN</Badge>}
              </div>
              {i === 0 && nodeHealth?.leader && (
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <span style={{ color: T.textDim }}>Leader</span>
                  <span style={{ fontFamily: "JetBrains Mono", color: T.amber, fontSize: 10 }}>
                    {nodeHealth.leader.split(":")[0]}
                  </span>
                </div>
              )}
              {i === 0 && nodeHealth?.term !== undefined && (
                <div style={{ display: "flex", justifyContent: "space-between" }}>
                  <span style={{ color: T.textDim }}>Term</span>
                  <span style={{ fontFamily: "JetBrains Mono", color: T.blue }}>{nodeHealth.term}</span>
                </div>
              )}
            </div>
          </Card>
        ))}
      </div>

      <Card style={{ marginBottom: 12 }}>
        <div style={{ color: T.textDim, fontSize: 10, marginBottom: 6, letterSpacing: "0.08em" }}>BASE URL</div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <input
            value={baseURL}
            onChange={e => setBaseURL(e.target.value)}
            style={{
              flex: 1, background: T.bgInput, border: `1px solid ${T.border}`,
              color: T.amber, padding: "6px 10px", borderRadius: 4,
              fontFamily: "JetBrains Mono", fontSize: 11,
            }}
          />
          <Btn onClick={async () => { setLoad("health", true); await api("GET", "/v1/sys/health", null, false); setLoad("health", false); }} loading={loading["health"]}>
            REFRESH
          </Btn>
        </div>
      </Card>

      <Card>
        <div style={{ color: T.textDim, fontSize: 10, marginBottom: 6, letterSpacing: "0.08em" }}>ROOT TOKEN</div>
        <div style={{ display: "flex", gap: 8, alignItems: "center" }}>
          <input
            value={token}
            onChange={e => setToken(e.target.value)}
            placeholder="paste root token here after init..."
            style={{
              flex: 1, background: T.bgInput, border: `1px solid ${T.border}`,
              color: T.amber, padding: "6px 10px", borderRadius: 4,
              fontFamily: "JetBrains Mono", fontSize: 11,
            }}
          />
          {token && <Badge color={T.green}>SET</Badge>}
        </div>
      </Card>
    </div>
  );

  const renderUnseal = () => (
    <div className="fade-in">
      <SectionHeader title="Init & Unseal" subtitle="Shamir K-of-N share ceremony — 3 shares, threshold 2" />

      <Card style={{ marginBottom: 12 }}>
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start", marginBottom: 12 }}>
          <div>
            <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 4 }}>Step 1 — Initialize Cluster</div>
            <div style={{ color: T.textDim, fontSize: 11 }}>
              Generates master key → splits into 3 Shamir shares (K=2) → returns root token
            </div>
          </div>
          <Btn onClick={doInit} loading={loading["init"]}>POST /sys/init</Btn>
        </div>
        {initResult && (
          <div>
            <div style={{ color: T.green, fontSize: 10, marginBottom: 8, letterSpacing: "0.08em" }}>
              ✓ INITIALIZED — SAVE THESE SHARES (shown once)
            </div>
            {initResult.shares.map((s, i) => (
              <div key={i} style={{
                marginBottom: 6, padding: "7px 12px", background: T.bg, borderRadius: 4,
                border: `1px solid ${T.amberDim}`, fontFamily: "JetBrains Mono",
                fontSize: 10, color: T.amber, wordBreak: "break-all",
              }}>
                <span style={{ color: T.textDim, marginRight: 8 }}>SHARE {i+1}</span>{s}
              </div>
            ))}
            <div style={{
              marginTop: 6, padding: "7px 12px", background: T.greenDim, borderRadius: 4,
              border: `1px solid ${T.green}44`, fontFamily: "JetBrains Mono",
              fontSize: 10, color: T.green, wordBreak: "break-all",
            }}>
              <span style={{ color: T.textDim, marginRight: 8 }}>ROOT TOKEN</span>{initResult.root_token}
            </div>
          </div>
        )}
      </Card>

      <Card style={{ marginBottom: 12 }}>
        <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 4 }}>Step 2 — Submit Shares (any 2 of 3)</div>
        <div style={{ color: T.textDim, fontSize: 11, marginBottom: 12 }}>
          Each share submitted one at a time. After K=2 shares, master key reconstructed, KEK loaded into /dev/shm, vault unseals.
        </div>
        {unsealProgress && (
          <div style={{
            marginBottom: 12, padding: "8px 12px", borderRadius: 4,
            background: unsealProgress.sealed === false ? T.greenDim : T.amberDim + "44",
            border: `1px solid ${unsealProgress.sealed === false ? T.green + "44" : T.amber + "44"}`,
            fontFamily: "JetBrains Mono", fontSize: 11,
            color: unsealProgress.sealed === false ? T.green : T.amber,
          }}>
            {unsealProgress.sealed === false
              ? `✓ UNSEALED — ${unsealProgress.progress} shares verified, KEK in memory`
              : `⬡ Progress: ${unsealProgress.progress} — submit another share`}
          </div>
        )}
        {[0, 1, 2].map(i => (
          <div key={i} style={{ display: "flex", gap: 8, alignItems: "center", marginBottom: 8 }}>
            <span style={{ color: T.textDim, fontFamily: "JetBrains Mono", fontSize: 10, width: 54, flexShrink: 0 }}>
              SHARE {i+1}
            </span>
            <input
              value={shares[i]}
              onChange={e => { const s = [...shares]; s[i] = e.target.value; setShares(s); }}
              placeholder={`paste share ${i+1}...`}
              style={{
                flex: 1, background: T.bgInput, border: `1px solid ${T.border}`,
                color: T.amber, padding: "5px 10px", borderRadius: 4,
                fontFamily: "JetBrains Mono", fontSize: 10,
              }}
            />
            <Btn small onClick={() => doUnseal(i)} loading={loading[`unseal${i}`]} disabled={!shares[i]}>
              SUBMIT
            </Btn>
          </div>
        ))}
      </Card>

      <Card style={{ borderColor: T.purple + "44" }}>
        <div style={{ color: T.purple, fontSize: 10, letterSpacing: "0.08em", marginBottom: 6 }}>MEMORY HYGIENE</div>
        <div style={{ color: T.textDim, fontSize: 11, lineHeight: 1.8 }}>
          After reconstruction: shares overwritten with{" "}
          <span style={{ fontFamily: "JetBrains Mono", color: T.text }}>dd if=/dev/zero</span> then deleted.
          Master key variable immediately set to empty string.
          KEK stored ONLY in{" "}
          <span style={{ fontFamily: "JetBrains Mono", color: T.text }}>/dev/shm/strongbox/kek</span>{" "}
          — RAM-backed tmpfs, never touches disk.
        </div>
      </Card>
    </div>
  );

  const renderSecrets = () => (
    <div className="fade-in">
      <SectionHeader title="Secrets Engine" subtitle="Envelope-encrypted, versioned secret storage" />
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
        <Card>
          <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 12 }}>Write Secret</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <Input label="Path" value={secretPath} onChange={setSecretPath} placeholder="app/db" mono />
            <div>
              <label style={{ color: T.textDim, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", display: "block", marginBottom: 4 }}>DATA (JSON)</label>
              <textarea value={secretData} onChange={e => setSecretData(e.target.value)} rows={3} style={{
                width: "100%", background: T.bgInput, border: `1px solid ${T.border}`,
                color: T.textBright, padding: "7px 12px", borderRadius: 4,
                fontFamily: "JetBrains Mono", fontSize: 11, resize: "vertical",
              }} />
            </div>
            <Btn onClick={doWriteSecret} loading={loading["writeSecret"]}>PUT /secrets/{secretPath}</Btn>
          </div>
        </Card>
        <Card>
          <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 12 }}>Read Secret</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 10 }}>
            <Input label="Path" value={secretPath} onChange={setSecretPath} placeholder="app/db" mono />
            <Input label="Version (blank = latest)" value={readVersion} onChange={setReadVersion} placeholder="1" mono />
            <Btn variant="success" onClick={doReadSecret} loading={loading["readSecret"]}>
              GET /secrets/{secretPath}{readVersion ? `?version=${readVersion}` : ""}
            </Btn>
          </div>
        </Card>
      </div>
      {secretResult && (
        <Card style={{ marginTop: 12 }}>
          <div style={{ color: T.textDim, fontSize: 10, letterSpacing: "0.08em", marginBottom: 8 }}>RESULT</div>
          <pre style={{ fontFamily: "JetBrains Mono", fontSize: 11, color: T.green, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
            {JSON.stringify(secretResult, null, 2)}
          </pre>
        </Card>
      )}
      <Card style={{ marginTop: 12, borderColor: T.blue + "33" }}>
        <div style={{ color: T.blue, fontSize: 10, letterSpacing: "0.08em", marginBottom: 8 }}>ENVELOPE ENCRYPTION FLOW</div>
        <div style={{ display: "flex", gap: 8 }}>
          {[
            { label: "1. GENERATE DEK", desc: "random 32-byte key\nper secret write", color: T.amber },
            { label: "2. ENCRYPT VALUE", desc: "AES-256-GCM\n(DEK, nonce, plaintext)", color: T.blue },
            { label: "3. WRAP DEK", desc: "AES-256-GCM\n(DEK encrypted with KEK)", color: T.purple },
            { label: "4. STORE", desc: "{ciphertext, wrapped_dek,\nnonce, dek_nonce}", color: T.green },
          ].map((s, i) => (
            <div key={i} style={{ flex: 1, padding: "8px 10px", background: T.bg, borderRadius: 4, border: `1px solid ${s.color}33` }}>
              <div style={{ color: s.color, fontSize: 9, fontFamily: "JetBrains Mono", marginBottom: 4, letterSpacing: "0.06em" }}>{s.label}</div>
              <div style={{ color: T.textDim, fontSize: 9, fontFamily: "JetBrains Mono", whiteSpace: "pre-line" }}>{s.desc}</div>
            </div>
          ))}
        </div>
      </Card>
    </div>
  );

  const renderAuth = () => (
    <div className="fade-in">
      <SectionHeader title="Auth & Policies" subtitle="Token management, policy enforcement — Scenario 4 & 5" />
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12, marginBottom: 12 }}>
        <Card>
          <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 12 }}>1. Create Policy</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <Input label="Policy Name" value={policyName} onChange={setPolicyName} mono />
            <div>
              <label style={{ color: T.textDim, fontSize: 10, letterSpacing: "0.08em", textTransform: "uppercase", display: "block", marginBottom: 4 }}>RULES (JSON)</label>
              <textarea value={policyRules} onChange={e => setPolicyRules(e.target.value)} rows={3} style={{
                width: "100%", background: T.bgInput, border: `1px solid ${T.border}`,
                color: T.textBright, padding: "7px 12px", borderRadius: 4,
                fontFamily: "JetBrains Mono", fontSize: 10, resize: "none",
              }} />
            </div>
            <Btn onClick={doCreatePolicy} loading={loading["policy"]}>PUT /policies/{policyName}</Btn>
          </div>
        </Card>
        <Card>
          <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 12 }}>2. Create User</div>
          <div style={{ display: "flex", flexDirection: "column", gap: 8 }}>
            <Input label="Username" value={newUsername} onChange={setNewUsername} mono />
            <Input label="Password" value={newPassword} onChange={setNewPassword} type="password" />
            <div style={{ color: T.textDim, fontSize: 10, padding: "6px 10px", background: T.bg, borderRadius: 4, fontFamily: "JetBrains Mono" }}>
              Assigned policy: <span style={{ color: T.amber }}>{policyName}</span>
            </div>
            <Btn onClick={doCreateUser} loading={loading["user"]}>PUT /users/{newUsername}</Btn>
          </div>
        </Card>
      </div>
      <Card style={{ marginBottom: 12 }}>
        <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 12 }}>3. Login → Scoped Token</div>
        <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr auto", gap: 8, alignItems: "end" }}>
          <Input label="Username" value={loginUser} onChange={setLoginUser} mono />
          <Input label="Password" value={loginPass} onChange={setLoginPass} type="password" />
          <Btn onClick={doLogin} loading={loading["login"]}>LOGIN</Btn>
        </div>
        {scopedToken && (
          <div style={{ marginTop: 10, padding: "7px 12px", background: T.bg, borderRadius: 4, border: `1px solid ${T.green}44`, fontFamily: "JetBrains Mono", fontSize: 10, color: T.green, wordBreak: "break-all" }}>
            <span style={{ color: T.textDim, marginRight: 8 }}>SCOPED TOKEN</span>{scopedToken}
          </div>
        )}
      </Card>
      {scopedToken && (
        <Card style={{ marginBottom: 12 }}>
          <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 8 }}>4. Test Policy Enforcement (Scenario 4)</div>
          <div style={{ display: "flex", gap: 8, flexWrap: "wrap", marginBottom: 8 }}>
            <Btn variant="success" onClick={() => testWithScopedToken("GET", `/v1/secrets/${secretPath}`)}>
              READ /secrets/{secretPath} → expect 200
            </Btn>
            <Btn variant="danger" onClick={() => testWithScopedToken("PUT", `/v1/secrets/${secretPath}`, { test: "hack" })}>
              WRITE /secrets/{secretPath} → expect 403
            </Btn>
          </div>
          <div style={{ color: T.textDim, fontSize: 11 }}>
            Policy <span style={{ color: T.amber, fontFamily: "JetBrains Mono" }}>{policyName}</span> allows{" "}
            <span style={{ color: T.green }}>read</span> only. Write and out-of-scope paths return 403.
          </div>
        </Card>
      )}
      {scopedToken && (
        <Card style={{ borderColor: T.red + "33" }}>
          <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 8 }}>5. Revoke Token (Scenario 5)</div>
          <div style={{ color: T.textDim, fontSize: 11, marginBottom: 10 }}>
            After revoke, the very next request returns 401 immediately — no cache, no grace period.
          </div>
          <div style={{ display: "flex", gap: 8 }}>
            <Btn variant="danger" onClick={doRevokeScoped} loading={loading["revoke"]}>POST /auth/revoke → 204</Btn>
            <Btn variant="ghost" onClick={() => testWithScopedToken("GET", `/v1/secrets/${secretPath}`)}>
              TEST READ → expect 401
            </Btn>
          </div>
        </Card>
      )}
    </div>
  );

  const renderDynamic = () => (
    <div className="fade-in">
      <SectionHeader title="Dynamic Postgres" subtitle="Scenario 6 & 7 — mint real roles, auto-revoke on expiry" />

      <Card style={{ marginBottom: 12 }}>
        <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 12 }}>Step 1 — Mint Dynamic Credential</div>
        <div style={{ display: "flex", gap: 8, alignItems: "end" }}>
          <div style={{ flex: 1 }}>
            <Input label="Role Template" value={dynamicRole} onChange={setDynamicRole} mono placeholder="readonly" />
          </div>
          <Btn onClick={doMintDynamic} loading={loading["dynamic"]}>GET /dynamic-postgres/{dynamicRole}</Btn>
        </div>
        {dynamicCred && (
          <div style={{ marginTop: 12 }}>
            <div style={{ color: T.green, fontSize: 10, letterSpacing: "0.08em", marginBottom: 8 }}>✓ CREDENTIAL MINTED</div>
            {[
              { label: "Username", value: dynamicCred.username, color: T.blue },
              { label: "Password", value: dynamicCred.password, color: T.amber },
              { label: "Lease ID", value: dynamicCred.lease_id, color: T.textDim },
              { label: "TTL",      value: `${dynamicCred.ttl}s`, color: T.text },
            ].map(({ label, value, color }) => (
              <div key={label} style={{ display: "flex", gap: 12, padding: "5px 10px", background: T.bg, borderRadius: 4, border: `1px solid ${T.border}`, marginBottom: 5, alignItems: "center" }}>
                <span style={{ color: T.textDim, fontSize: 10, fontFamily: "JetBrains Mono", width: 65, flexShrink: 0 }}>{label.toUpperCase()}</span>
                <span style={{ fontFamily: "JetBrains Mono", fontSize: 10, color, wordBreak: "break-all" }}>{value}</span>
              </div>
            ))}
          </div>
        )}
      </Card>

      {dynamicCred && (
        <Card style={{ marginBottom: 12, borderColor: T.red + "33" }}>
          <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 4 }}>Step 2 — Scenario 7: Stop Postgres (DB Down)</div>
          <div style={{ color: T.textDim, fontSize: 11, marginBottom: 10 }}>
            Run this on your VPS to stop Postgres and trigger <span style={{ fontFamily: "JetBrains Mono", color: T.amber }}>revocation_pending</span> state:
          </div>
          <div style={{ padding: "10px 14px", background: T.bg, borderRadius: 4, border: `1px solid ${T.border}`, fontFamily: "JetBrains Mono", fontSize: 11, color: T.amber, marginBottom: 10 }}>
            docker compose stop postgres
          </div>
          <div style={{ display: "flex", gap: 8, marginBottom: 10 }}>
            <Btn variant="danger" onClick={doRevokeDynamic} loading={loading["revokeDynamic"]}>
              REVOKE LEASE (while DB down)
            </Btn>
            <Btn variant="ghost" onClick={() => pollLeaseState(dynamicCred?.lease_id)} loading={leasePolling}>
              CHECK LEASE STATE
            </Btn>
          </div>
          {leaseState && (
            <div style={{
              padding: "8px 12px", borderRadius: 4,
              background: leaseState.state === "revocation_pending" ? T.amberDim + "44" :
                         leaseState.state === "revoked" ? T.greenDim :
                         leaseState.state === "active" ? T.blueDim : T.bgInput,
              border: `1px solid ${
                leaseState.state === "revocation_pending" ? T.amber + "44" :
                leaseState.state === "revoked" ? T.green + "44" :
                leaseState.state === "active" ? T.blue + "44" : T.border
              }`,
              fontFamily: "JetBrains Mono", fontSize: 11,
            }}>
              <span style={{ color: T.textDim, marginRight: 8 }}>STATE</span>
              <span style={{ color:
                leaseState.state === "revocation_pending" ? T.amber :
                leaseState.state === "revoked" ? T.green :
                leaseState.state === "active" ? T.blue : T.textDim
              }}>{leaseState.state?.toUpperCase()}</span>
              {leaseState.ttl_remaining !== undefined && (
                <span style={{ color: T.textDim, marginLeft: 16 }}>TTL remaining: {leaseState.ttl_remaining}s</span>
              )}
            </div>
          )}
          <div style={{ marginTop: 10, color: T.textDim, fontSize: 11 }}>
            Then restart Postgres and keep clicking CHECK LEASE STATE:
          </div>
          <div style={{ marginTop: 6, padding: "10px 14px", background: T.bg, borderRadius: 4, border: `1px solid ${T.border}`, fontFamily: "JetBrains Mono", fontSize: 11, color: T.green }}>
            docker compose start postgres
          </div>
          <div style={{ marginTop: 8, color: T.textDim, fontSize: 11 }}>
            The reaper retries with exponential backoff. When Postgres recovers, state transitions to{" "}
            <span style={{ fontFamily: "JetBrains Mono", color: T.green }}>revoked</span> automatically.
          </div>
        </Card>
      )}

      <Card style={{ borderColor: T.blue + "33" }}>
        <div style={{ color: T.blue, fontSize: 10, letterSpacing: "0.08em", marginBottom: 8 }}>BACKOFF STATES</div>
        <div style={{ display: "flex", gap: 6 }}>
          {[
            { step: "ACTIVE",    detail: "role in pg_roles\ncredential works",    color: T.green },
            { step: "EXPIRED",   detail: "TTL elapsed\nreaper detects",           color: T.textDim },
            { step: "DB DOWN",   detail: "revoke fails\n→ pending\nbackoff starts", color: T.red },
            { step: "RETRY",     detail: "2→4→8→16\n→32→60s\n(capped)",           color: T.amber },
            { step: "REVOKED",   detail: "DB recovers\nDROP ROLE ok\nno manual",   color: T.green },
          ].map((s, i) => (
            <div key={i} style={{ flex: 1, padding: "8px 10px", background: T.bg, borderRadius: 4, border: `1px solid ${s.color}44` }}>
              <div style={{ color: s.color, fontSize: 9, fontFamily: "JetBrains Mono", marginBottom: 4 }}>{s.step}</div>
              <div style={{ color: T.textDim, fontSize: 9, fontFamily: "JetBrains Mono", whiteSpace: "pre-line", lineHeight: 1.6 }}>{s.detail}</div>
            </div>
          ))}
        </div>
      </Card>
    </div>
  );

  const renderAudit = () => (
    <div className="fade-in">
      <SectionHeader title="Audit Log & Verify" subtitle="Scenario 10 — tamper-evident HMAC chain" />

      <Card style={{ marginBottom: 12 }}>
        <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 8 }}>Step 1 — Fetch Audit Entries</div>
        <Btn onClick={async () => {
          setLoad("audit", true);
          const r = await api("GET", "/v1/audit");
          if (r.ok && Array.isArray(r.data)) setAuditLog(r.data);
          setLoad("audit", false);
        }} loading={loading["audit"]}>GET /audit</Btn>
        {auditLog.length > 0 && (
          <div style={{ marginTop: 10, maxHeight: 160, overflowY: "auto" }}>
            {auditLog.map((entry, i) => (
              <div key={i} style={{ display: "flex", gap: 12, padding: "4px 8px", borderBottom: `1px solid ${T.border}`, fontSize: 10, fontFamily: "JetBrains Mono" }}>
                <span style={{ color: T.textDim, width: 20 }}>{i}</span>
                <span style={{ color: T.blue, width: 80 }}>{entry.op}</span>
                <span style={{ color: T.text, flex: 1 }}>{entry.path}</span>
                <span style={{ color: T.textDim }}>{entry.ts?.slice(0, 19)}</span>
              </div>
            ))}
          </div>
        )}
      </Card>

      <Card style={{ marginBottom: 12 }}>
        <div style={{ color: T.textBright, fontWeight: 600, marginBottom: 4 }}>Step 2 — Run strongbox-verify</div>
        <div style={{ color: T.textDim, fontSize: 11, marginBottom: 12 }}>
          Calls <span style={{ fontFamily: "JetBrains Mono", color: T.text }}>GET /v1/sys/audit/verify</span> which runs
          <span style={{ fontFamily: "JetBrains Mono", color: T.amber }}> strongbox-verify</span> inside the container and returns the result.
        </div>
        <div style={{ display: "flex", gap: 8, marginBottom: 12 }}>
          <Btn variant="success" onClick={() => doAuditVerify(false)} loading={loading["verifyClean"]}>
            VERIFY CLEAN LOG → expect OK
          </Btn>
          <Btn variant="danger" onClick={() => doAuditVerify(true)} loading={loading["verifyTamper"]}>
            TAMPER + VERIFY → expect TAMPERED
          </Btn>
        </div>

        {verifyResult && (
          <div style={{
            padding: "12px 14px", borderRadius: 4,
            background: verifyResult.result === "OK" ? T.greenDim : T.redDim,
            border: `1px solid ${verifyResult.result === "OK" ? T.green + "44" : T.red + "44"}`,
          }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
              <span style={{ fontSize: 16 }}>{verifyResult.result === "OK" ? "✓" : "✗"}</span>
              <span style={{ fontFamily: "JetBrains Mono", fontWeight: 600, fontSize: 13, color: verifyResult.result === "OK" ? T.green : T.red }}>
                {verifyResult.result}
              </span>
              {verifyResult.tampered_test && (
                <Badge color={T.amber}>TAMPER TEST</Badge>
              )}
            </div>
            <pre style={{ fontFamily: "JetBrains Mono", fontSize: 11, color: verifyResult.result === "OK" ? T.green : T.red, whiteSpace: "pre-wrap", wordBreak: "break-all" }}>
              {verifyResult.output}
            </pre>
          </div>
        )}
      </Card>

      <Card style={{ borderColor: T.purple + "33" }}>
        <div style={{ color: T.purple, fontSize: 10, letterSpacing: "0.08em", marginBottom: 8 }}>HOW THE HMAC CHAIN WORKS</div>
        <div style={{ color: T.textDim, fontSize: 11, lineHeight: 1.8 }}>
          Each entry: <span style={{ fontFamily: "JetBrains Mono", color: T.text }}>entry_hash = SHA256(prev_hash + fields)</span>
          <br />Each entry: <span style={{ fontFamily: "JetBrains Mono", color: T.text }}>hmac = HMAC-SHA256(audit_key, entry_hash)</span>
          <br />The TAMPER test flips one byte at position 50 in a copy of the log, then runs the verifier.
          <br />One byte change → <span style={{ fontFamily: "JetBrains Mono", color: T.red }}>entry_hash mismatch</span> → verifier exits non-zero naming the entry.
        </div>
      </Card>
    </div>
  );

  const sections = { health: renderHealth, unseal: renderUnseal, secrets: renderSecrets, auth: renderAuth, dynamic: renderDynamic, audit: renderAudit };
  const navItems = [
    { id: "health",  label: "Cluster Status",   icon: "◉" },
    { id: "unseal",  label: "Init & Unseal",     icon: "⬡" },
    { id: "secrets", label: "Secrets",           icon: "⊟" },
    { id: "auth",    label: "Auth & Policies",   icon: "⬑" },
    { id: "dynamic", label: "Dynamic Postgres",  icon: "⬡" },
    { id: "audit",   label: "Audit Log",          icon: "⊕" },
  ];

  return (
    <>
      <style>{globalStyles}</style>
      <div style={{ display: "flex", height: "100vh", overflow: "hidden" }}>
        {/* Sidebar */}
        <div style={{ width: 200, flexShrink: 0, background: T.bgCard, borderRight: `1px solid ${T.border}`, display: "flex", flexDirection: "column" }}>
          <div style={{ padding: "16px 16px 12px", borderBottom: `1px solid ${T.border}` }}>
            <div style={{ display: "flex", alignItems: "center", gap: 8, marginBottom: 8 }}>
              <div style={{ width: 28, height: 28, background: T.amber + "22", border: `1px solid ${T.amber}44`, borderRadius: 4, display: "flex", alignItems: "center", justifyContent: "center", fontSize: 14, color: T.amber }}>⬡</div>
              <div>
                <div style={{ color: T.textBright, fontWeight: 700, fontSize: 13, fontFamily: "JetBrains Mono" }}>STRONGBOX</div>
                <div style={{ color: T.textDim, fontSize: 9, letterSpacing: "0.05em" }}>DEMO CONSOLE</div>
              </div>
            </div>
            <div style={{ display: "flex", alignItems: "center", gap: 6 }}>
              <StatusDot status={sealed ? "sealed" : "up"} />
              <span style={{ fontSize: 10, fontFamily: "JetBrains Mono", color: sealed ? T.amber : T.green }}>
                {sealed ? "SEALED" : "UNSEALED"}
              </span>
            </div>
          </div>
          <div style={{ flex: 1, padding: "8px", overflowY: "auto" }}>
            {navItems.map(item => (
              <button key={item.id} onClick={() => setActiveSection(item.id)} style={{
                display: "flex", alignItems: "center", gap: 8, width: "100%",
                padding: "7px 10px", borderRadius: 4, marginBottom: 2, textAlign: "left",
                background: activeSection === item.id ? T.amber + "15" : "transparent",
                border: `1px solid ${activeSection === item.id ? T.amber + "33" : "transparent"}`,
                color: activeSection === item.id ? T.amber : T.textDim,
                cursor: "pointer", fontSize: 11,
                fontWeight: activeSection === item.id ? 500 : 400, transition: "all 0.15s",
              }}>
                <span style={{ fontSize: 12, opacity: 0.7 }}>{item.icon}</span>
                {item.label}
              </button>
            ))}
          </div>
          {nodeHealth && (
            <div style={{ padding: "10px 12px", borderTop: `1px solid ${T.border}` }}>
              <div style={{ fontSize: 9, color: T.textDim, fontFamily: "JetBrains Mono", marginBottom: 3 }}>CLUSTER</div>
              <div style={{ fontSize: 10, fontFamily: "JetBrains Mono", color: T.textDim }}>
                term <span style={{ color: T.blue }}>{nodeHealth.term}</span>
                {nodeHealth.leader && <> · <span style={{ color: T.amber }}>{nodeHealth.leader.split(":")[0]}</span></>}
              </div>
            </div>
          )}
        </div>
        {/* Content */}
        <div style={{ flex: 1, display: "flex", overflow: "hidden" }}>
          <div style={{ flex: 1, overflowY: "auto", padding: 20 }}>
            {(sections[activeSection] || sections.health)()}
          </div>
          {/* Terminal */}
          <div style={{ width: 340, flexShrink: 0, padding: "12px 12px 12px 0" }}>
            <Terminal logs={logs} />
          </div>
        </div>
      </div>
    </>
  );
}
